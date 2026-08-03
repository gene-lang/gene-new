// The web-profile shell for the protocol spec.
//
//   gene build --target web probes/protocol_spec.gene --out-dir dist
//   node tools/protocol_spec.mjs

import { report, failures } from "../dist/protocol_spec.mjs";

process.stdout.write(report() + "\n\n");
const bad = failures();
process.stdout.write(bad === 0
  ? "PASS — every check agrees\n"
  : `FAIL — ${bad} check(s) failed\n`);
if (bad !== 0) process.exit(1);
