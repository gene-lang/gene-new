#!/bin/bash
# usage: pgo-build.sh PHASE TREE NAME OUT   (PHASE: instr | train | final)
#
# The `nimble speedy_pgo` recipe (gene.nimble) split into phases, so that the
# two sides of an A/B comparison can build in parallel while their trainings
# run one at a time. TREE is a source tree (`git archive REV | tar -x`, plus
# nimble.paths); the binary is written to OUT/gene-NAME-pgo, and the logs,
# nimcaches and profile to OUT/pgo-NAME/.
set -u
PH=$1; T=$2; N=$3; OUT=$4; P=$OUT/pgo-$N
mkdir -p "$P"
cd "$T"
FLAGS="-d:release --mm:orc --opt:speed --hints:off"
log() { echo "$(date +%T) $*" >> "$P/steps.log"; }
case $PH in
instr)
  log instr-start
  nim c $FLAGS --passC:"-march=native -O3 -fprofile-instr-generate" \
    --passL:"-fprofile-instr-generate" --nimcache:"$P/nc-instr" \
    -o:"$P/gene-instrumented" src/gene.nim > "$P/build-instr.log" 2>&1 ||
    { log instr-failed; exit 1; }
  log instr-done ;;
train)
  log train-start
  rm -rf "$P/profile"
  sh tools/pgo/train.sh "$P/gene-instrumented" "$P/profile" > "$P/train.log" 2>&1
  xcrun llvm-profdata merge -o "$P/gene.profdata" "$P/profile" \
    > "$P/merge.log" 2>&1 || { log merge-failed; exit 1; }
  log train-done ;;
final)
  log final-start
  nim c $FLAGS --passC:"-march=native -O3 -fprofile-instr-use=$P/gene.profdata" \
    --nimcache:"$P/nc-final" -o:"$OUT/gene-$N-pgo" src/gene.nim \
    > "$P/build-final.log" 2>&1 || { log final-failed; exit 1; }
  log final-done ;;
esac
