// The web-profile shell for the mapgen cross-backend spec.
//
//   gene build --target web probes/mapgen_spec.gene --out-dir dist
//   node tools/mapgen_spec.mjs
//
// Counterpart to probes/run_mapgen_spec.gene. Both print the same report and
// add nothing to it, so a difference between the two outputs is a difference
// between the runtimes — which for §D3.1's exact half means the server and the
// client would generate different worlds.

import { report, failures } from "../dist/mapgen_spec.mjs";

process.stdout.write(report() + "\n\n");
const bad = failures();
process.stdout.write(bad === 0
  ? "PASS — every check agrees\n"
  : `FAIL — ${bad} check(s) failed\n`);
if (bad !== 0) process.exit(1);
