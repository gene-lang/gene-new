// The web-profile shell for the ABM cross-backend spec.
//
//   gene build --target web probes/abm_spec.gene --out-dir dist
//   node tools/abm_spec.mjs
//
// Counterpart to probes/run_abm_spec.gene. Both print the same report and add
// nothing to it, so a difference between the two outputs is a difference
// between the runtimes.

import { report, failures } from "../dist/abm_spec.mjs";

process.stdout.write(report() + "\n\n");
const bad = failures();
process.stdout.write(bad === 0
  ? "PASS — every check agrees\n"
  : `FAIL — ${bad} check(s) failed\n`);
if (bad !== 0) process.exit(1);
