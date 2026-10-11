#!/bin/zsh
# usage: run.sh CANDIDATE — compare program and eval outputs with the baseline binary
CAND=$1; BASE=tmp/perf2/gene-baseline; D=tmp/perf2/diff; ok=1
check() { # label, base-output-file, candidate-output-file
  if cmp -s $2 $3; then echo "SAME  $1 ($(wc -l < $2 | tr -d ' ') lines)"
  else echo "DIFF  $1"; diff $2 $3 | head -20; ok=0; fi
}
for f in $D/*.gene $D/mods/main.gene; do
  n=$(basename $f .gene)
  $BASE run $f > $D/$n.base.out 2>&1; $CAND run $f > $D/$n.cand.out 2>&1
  check $(basename $f) $D/$n.base.out $D/$n.cand.out
done
: > $D/evals.base.out; : > $D/evals.cand.out
while IFS= read -r src; do
  [ -z "$src" ] && continue
  $BASE eval "$src" >> $D/evals.base.out 2>&1; $CAND eval "$src" >> $D/evals.cand.out 2>&1
done < $D/evals.txt
check evals.txt $D/evals.base.out $D/evals.cand.out
[ $ok = 1 ] && echo ALL-SAME
exit 0
