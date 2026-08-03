// The web-profile shell for the selection-and-edit spec.
//
//   gene build --target web probes/edit_spec.gene --out-dir dist
//   node tools/edit_spec.mjs
//
// Counterpart to probes/run_edit_spec.gene. Both print the same report and add
// nothing to it, so a difference between the two outputs is a difference
// between the runtimes.

import { report, failures } from "../dist/edit_spec.mjs";

process.stdout.write(report() + "\n\n");
const bad = failures();
process.stdout.write(bad === 0
  ? "PASS — every check agrees\n"
  : `FAIL — ${bad} check(s) failed\n`);
if (bad !== 0) process.exit(1);
