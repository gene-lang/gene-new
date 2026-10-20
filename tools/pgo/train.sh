#!/bin/sh
# Run a profile-instrumented gene binary over the PGO training workloads:
# example programs, the VM operation benchmark, tools/pgo/workload.gene,
# compiling the Harness sources, and the Harness unit, storage, built-in plugin
# and agent specs. Every process, including each isolated spec, merges its
# counters into a pool of .profraw files under PROFILE_DIR.
# usage: train.sh INSTRUMENTED_GENE PROFILE_DIR
set -e
GENE=$1
OUT=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$OUT"
export LLVM_PROFILE_FILE="$OUT/gene-%4m.profraw"
cd "$ROOT"
for f in macro pipeline generators protocol_demo error_handling events \
    fexpr_demo nil_void_demo simple style_guide; do
  "$GENE" run "examples/$f.gene" > /dev/null
done
"$GENE" run benchmarks/ops.gene 200000 > /dev/null
"$GENE" run tools/pgo/workload.gene 4
for f in examples/gene-harness/src/*.gene examples/gene-harness/src/*/*.gene; do
  "$GENE" compile "$f" > /dev/null 2>&1 || true
done
cd examples/gene-harness
# A failing spec still runs, so it trains as well as a passing one.
"$GENE" test tests/unit tests/integration/storage tests/integration/builtin \
  tests/integration/agents ||
  echo "train.sh: some training specs failed; their counters still count" >&2
