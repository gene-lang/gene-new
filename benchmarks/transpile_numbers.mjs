// P0.5 numeric representation spike (docs/proposals/transpile.md §4.5/§8).
// Measures the cost B pays at the browser's dominant boundary: parse a real
// JSON-shaped payload, adapt schema-known Int fields to bigint, compute over
// them, and adapt back to JSON-safe decimal strings.

import { readFileSync } from "node:fs";
import { performance } from "node:perf_hooks";

const payloadPath = new URL("./data/transpile_numbers.json", import.meta.url);
const source = readFileSync(payloadPath, "utf8");
const iterations = Number(process.env.GENE_NUMERIC_BENCH_ITERS ?? 20_000);

const intKeys = new Set([
  "generated_at_ms", "id", "quantity", "unit_cents", "offset", "limit", "total",
]);

function toBigIntProfile(value, key = "") {
  if (Array.isArray(value)) return value.map((item) => toBigIntProfile(item));
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([name, item]) => [name, toBigIntProfile(item, name)]),
    );
  }
  if (typeof value === "number" && intKeys.has(key)) {
    if (!Number.isSafeInteger(value)) throw new RangeError(`unsafe JSON Int at ${key}`);
    return BigInt(value);
  }
  return value;
}

function bigintJsonAdapter(_key, value) {
  return typeof value === "bigint" ? { $gene_int: value.toString() } : value;
}

function totalNumber(payload) {
  let total = 0;
  for (const item of payload.items) total += item.quantity * item.unit_cents;
  return total;
}

function totalBigInt(payload) {
  let total = 0n;
  for (const item of payload.items) total += item.quantity * item.unit_cents;
  return total;
}

function measure(label, operation) {
  for (let i = 0; i < 500; i += 1) operation();
  const started = performance.now();
  let result;
  for (let i = 0; i < iterations; i += 1) result = operation();
  const elapsedMs = performance.now() - started;
  return { label, elapsed_ms: elapsedMs, ns_per_op: elapsedMs * 1e6 / iterations, result };
}

const numberPayload = JSON.parse(source);
const bigintPayload = toBigIntProfile(numberPayload);
const rows = [
  measure("json.parse.number", () => JSON.parse(source).items.length),
  measure("json.parse_and_adapt.bigint", () => toBigIntProfile(JSON.parse(source)).items.length),
  measure("compute.number", () => totalNumber(numberPayload)),
  measure("compute.bigint", () => totalBigInt(bigintPayload)),
  measure("json.stringify.number", () => JSON.stringify(numberPayload).length),
  measure("json.stringify.bigint_adapter", () => JSON.stringify(bigintPayload, bigintJsonAdapter).length),
];

let nativeBigintJson = "accepted";
try {
  JSON.stringify(1n);
} catch (error) {
  nativeBigintJson = error.name;
}

console.log(`numeric spike: node=${process.version} iterations=${iterations} payload_bytes=${source.length}`);
for (const row of rows) {
  const printable = typeof row.result === "bigint" ? row.result.toString() : row.result;
  console.log(`${row.label.padEnd(34)} ${row.ns_per_op.toFixed(1).padStart(10)} ns/op  result=${printable}`);
}
console.log(`JSON.stringify(1n)=${nativeBigintJson}`);
