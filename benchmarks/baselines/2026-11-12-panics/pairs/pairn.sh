#!/bin/bash
# usage: pairn.sh ROUNDS OUT KERNEL_FILE LABEL=BIN ...
# Runs KERNEL_FILE on every binary each round, rotating the order, and
# appends "round<TAB>label<TAB>kernel<TAB>ms" rows to OUT.
R=$1; OUT=$2; K=$3; shift 3
labels=(); bins=()
for spec in "$@"; do labels+=("${spec%%=*}"); bins+=("${spec#*=}"); done
n=${#bins[@]}
: > "$OUT"
for i in $(seq 0 $((n - 1))); do "${bins[$i]}" run "$K" >/dev/null 2>&1; done
for r in $(seq 1 "$R"); do
  for j in $(seq 0 $((n - 1))); do
    i=$(( (j + r) % n ))
    "${bins[$i]}" run "$K" 2>&1 | awk -v r="$r" -v w="${labels[$i]}" -F'\t' \
      'NF>=2 {print r"\t"w"\t"$1"\t"$2}' >> "$OUT"
  done
done
