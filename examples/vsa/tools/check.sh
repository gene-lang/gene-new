#!/bin/sh
# The actual gate: the same source, both runtimes, byte-identical reports.
#
#   tools/check.sh
#
# A difference here is a difference between the VM and the web profile, because
# the shared module prints nothing — both shells only wrap `report`.
#
# Temp files rather than `diff <(a) <(b)`: process substitution is a bashism and
# this runs under /bin/sh.
set -e
cd "$(dirname "$0")/.."

gene build --target web tests/web_algebra.gene --out-dir dist >/dev/null

vm=$(mktemp)
web=$(mktemp)
trap 'rm -f "$vm" "$web"' EXIT

gene run algebra > "$vm"
node -e "import('./dist/web_algebra.mjs').then(m => m.main())" > "$web"

if diff "$vm" "$web"; then
  printf 'cross-backend: identical\n'
  tail -1 "$vm"
else
  printf 'cross-backend: DIVERGED\n'
  exit 1
fi
