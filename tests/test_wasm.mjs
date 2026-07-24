// Node validation harness for the Gene wasm host ABI v0 (docs/wasm.md §A.4).
//
//   nimble wasm            # builds web/gene.js + web/gene.wasm
//   node tests/test_wasm.mjs   # runs this
//
// Demonstrates the whole boundary: alloc a source buffer, gene_eval, read the
// status + rendered result + captured print output back out of wasm memory,
// gene_result_free. No raw Gene value ever crosses to JS — only i32 handles and
// UTF-8 byte ranges.

import GeneModule from '../web/gene.js';

const M = await GeneModule();

function geneEval(src) {
  const bytes = new TextEncoder().encode(src);
  const p = M._gene_alloc(bytes.length);
  if (bytes.length > 0 && p === 0) throw new Error("gene_alloc failed");
  if (bytes.length > 0) M.HEAPU8.set(bytes, p);
  const h = M._gene_eval(p, bytes.length);
  if (h === 0) throw new Error("gene_eval rejected input");
  M._gene_free(p);
  const readStr = (ptr, len) => len === 0 ? "" :
      new TextDecoder().decode(M.HEAPU8.subarray(ptr, ptr + len));
  const result = {
    status: M._gene_result_status(h),
    text:   readStr(M._gene_result_text_ptr(h), M._gene_result_text_len(h)),
    out:    readStr(M._gene_result_out_ptr(h),  M._gene_result_out_len(h)),
  };
  M._gene_result_free(h);
  return result;
}

// [source, expected status, expected text, expected captured output]
const cases = [
  ["", 0, "nil", ""],
  ["(+ 1 2)", 0, "3", ""],
  ["(if true 1 2)", 0, "1", ""],
  ["[true false nil]", 0, "[true false nil]", ""],
  ['($println "hi")', 0, "nil", "hi\n"],
  ['($str/join ["a" "b"] "-")', 0, '"a-b"', ""],
  ['(import $log [new_logger debug!]) ' +
   '(var logger (new_logger "app/wasm")) ' +
   '(var touched ($cell false)) ' +
   '(debug! logger (do (Cell/set touched true) "hidden")) ' +
   '(Cell/get touched)', 0, "false", ""],
  ["($json/stringify {^a 1 ^b [true nil]})", 0, '"{\\"a\\":1,\\"b\\":[true,null]}"', ""],
  ["(foo-undefined)", 1, "undefined symbol: foo-undefined", ""],
  ["(((", 3,
    "unexpected EOF: unclosed '('\n" +
      "  while reading '(' opened at 1:3; expected ')'\n" +
      "  while reading '(' opened at 1:2; expected ')'\n" +
      "  while reading '(' opened at 1:1; expected ')'",
    ""],
];

let failed = 0;
for (const [src, wantStatus, wantText, wantOut] of cases) {
  const r = geneEval(src);
  const ok = r.status === wantStatus && r.text === wantText && r.out === wantOut;
  if (!ok) {
    failed++;
    console.error(`FAIL ${src}`);
    console.error(`  got   status=${r.status} text=${JSON.stringify(r.text)} out=${JSON.stringify(r.out)}`);
    console.error(`  want  status=${wantStatus} text=${JSON.stringify(wantText)} out=${JSON.stringify(wantOut)}`);
  } else {
    console.log(`ok   ${src}  ->  ${JSON.stringify(r.text)}${r.out ? "  out=" + JSON.stringify(r.out) : ""}`);
  }
}

const logResult = geneEval(
  '(import $log [new_logger]) ' +
  '(var logger (new_logger "app/wasm" ^payload {^token "secret"})) ' +
  '(logger ~ warn "host warning")');
if (logResult.status !== 0 || logResult.text !== "nil" ||
    !logResult.out.includes('^level "warn"') ||
    !logResult.out.includes('^logger "app/wasm"') ||
    !logResult.out.includes('^message "host warning"') ||
    !logResult.out.includes('[redacted]')) {
  failed++;
  console.error("FAIL wasm host logging sink");
  console.error(`  got ${JSON.stringify(logResult)}`);
} else {
  console.log("ok   wasm host logging sink captures redacted output");
}
console.log(failed === 0 ? `\nall ${cases.length} wasm ABI cases passed` : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
