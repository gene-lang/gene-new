// The web shell for design.md §D6.2's divergence probe.
//
//   gene run build_probes      # or: gene build --target web probes/divergence.gene --out-dir dist
//   node tools/divergence.mjs
//
// The counterpart to probes/run_divergence.gene. Both call `report()` and print
// it; neither adds anything, so a difference between the two outputs is a
// difference between the runtimes and nothing else.

import { report } from "../dist/divergence.mjs";

process.stdout.write(report() + "\n");
