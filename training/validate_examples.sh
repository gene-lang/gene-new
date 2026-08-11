#!/usr/bin/env bash
# Validate generated corpus examples against everything the training pipeline
# will later demand of them, so a bad example is caught at authoring time
# rather than silently dropped by build_corpus.py.
#
# Each example is a pair:
#   <name>.gene       a small, self-contained program
#   <name>.expected   its exact expected stdout
#
# The `.expected` file is what makes the Model-training study's semantic gates
# (G4/G5) measurable at all: `gene test` is package-level, so a loose corpus
# file cannot declare tests, but a deterministic stdout oracle needs no package
# context and is a real pass/fail signal.
#
# Four checks, in the order they catch the most:
#   1. compile   - macro expansion and name resolution
#   2. run       - stdout matches .expected exactly, exit 0.  Strictly stronger
#                  than compile: `(% x 2)` compiles fine and fails at runtime,
#                  because `%` is unquote sugar and the remainder operator is
#                  `//` (design §7.4).
#   3. docpack   - program_document v0 can encode it (no regex/range/date-family
#                  /bigint literals)
#   4. units     - `docunits --decode` reproduces the canonical text exactly
#                  (the study's zero-representation-loss gate)
#
# Usage: training/validate_examples.sh <dir> [gene_binary]
# Exit 0 iff every example passes all four. Prints one line per failure.

set -uo pipefail

DIR="${1:?usage: validate_examples.sh <dir> [gene_binary]}"
GENE="${2:-bin/gene}"

if [ ! -x "$GENE" ]; then
  echo "gene binary not found or not executable: $GENE" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Gene diagnostics are multi-line (message, then a source excerpt with a
# caret); `tail -1` would report the caret line, which says nothing.
first_error() { grep -m1 -E 'Error|error:' "$1" 2>/dev/null || head -1 "$1"; }

total=0; passed=0; failed=0

while IFS= read -r src; do
  total=$((total + 1))
  base="${src%.gene}"
  expected="$base.expected"
  name="${src#"$DIR"/}"

  if [ ! -f "$expected" ]; then
    echo "FAIL $name: no .expected file"; failed=$((failed + 1)); continue
  fi

  if ! "$GENE" compile "$src" >/dev/null 2>"$TMP/err"; then
    echo "FAIL $name: compile: $(first_error "$TMP/err")"; failed=$((failed + 1)); continue
  fi

  if ! "$GENE" run "$src" >"$TMP/out" 2>"$TMP/err"; then
    echo "FAIL $name: run exited non-zero: $(first_error "$TMP/err")"; failed=$((failed + 1)); continue
  fi
  if ! cmp -s "$TMP/out" "$expected"; then
    echo "FAIL $name: stdout != .expected"; failed=$((failed + 1)); continue
  fi

  if ! "$GENE" docpack "$src" -o "$TMP/d.gdoc" 2>"$TMP/err"; then
    echo "FAIL $name: docpack: $(first_error "$TMP/err")"; failed=$((failed + 1)); continue
  fi

  "$GENE" docunits "$src" -o "$TMP/d.units.jsonl" 2>/dev/null
  "$GENE" docunpack "$TMP/d.gdoc" >"$TMP/canon.gene" 2>/dev/null
  "$GENE" docunits --decode "$TMP/d.units.jsonl" >"$TMP/dec.gene" 2>"$TMP/err"
  if ! cmp -s "$TMP/canon.gene" "$TMP/dec.gene"; then
    echo "FAIL $name: units round-trip lost information"; failed=$((failed + 1)); continue
  fi

  passed=$((passed + 1))
done < <(find "$DIR" -name '*.gene' -type f | sort)

echo "---"
echo "examples: $total  passed: $passed  failed: $failed"
[ "$failed" -eq 0 ] && [ "$total" -gt 0 ]
