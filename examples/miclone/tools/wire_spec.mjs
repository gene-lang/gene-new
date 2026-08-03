// The web-profile shell for the wire codec spec.
//
//   gene build --target web probes/wire_spec.gene --out-dir dist
//   node tools/wire_spec.mjs
//
// Counterpart to probes/run_wire_spec.gene.

import { report, failures } from "../dist/wire_spec.mjs";

process.stdout.write(report() + "\n\n");
const bad = failures();
process.stdout.write(bad === 0
  ? "PASS — every check agrees\n"
  : `FAIL — ${bad} check(s) failed\n`);
if (bad !== 0) process.exit(1);
