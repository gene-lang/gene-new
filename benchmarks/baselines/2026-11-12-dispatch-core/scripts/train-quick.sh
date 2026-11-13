#!/bin/sh
# train.sh without the Harness specs, whose counters depend on timing.
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
