#!/usr/bin/env bash
# Run the native-unit arm and the matched canonical-.gene-byte control arm
# back to back with IDENTICAL hyperparameters (docs/proposals/
# reversible-ai-native-program-format.md, "Model-training study": "The two
# arms use the same backbone capacity, optimizer, training-example pool,
# total training-FLOP budget, maximum context positions, and evaluation
# tasks"). This script is the single source of truth for that match --
# hand-typing two `train.py` invocations risks a silent mismatch that would
# quietly invalidate the comparison.
#
# Usage: training/run_matched.sh <corpus_dir> <out_dir> [extra train.py flags...]
# Example:
#   training/run_matched.sh training/corpus/out training/checkpoints/pilot1 \
#       --context-len 1024 --d-model 512 --n-layers 8 --n-heads 8 --steps 20000

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <corpus_dir> <out_dir> [extra train.py flags...]" >&2
  exit 1
fi

CORPUS="$1"
OUT="$2"
shift 2
EXTRA_FLAGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== units arm ==="
python3 "$SCRIPT_DIR/train.py" --corpus "$CORPUS" --arm units \
  --out "$OUT/units" "${EXTRA_FLAGS[@]}"

echo "=== bytes arm (matched control) ==="
python3 "$SCRIPT_DIR/train.py" --corpus "$CORPUS" --arm bytes \
  --out "$OUT/bytes" "${EXTRA_FLAGS[@]}"

echo "=== done: $OUT/units and $OUT/bytes ==="
