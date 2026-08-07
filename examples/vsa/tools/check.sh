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

vm=$(mktemp)
web=$(mktemp)
trap 'rm -f "$vm" "$web"' EXIT

status=0
for suite in algebra cleanup codec; do
  gene build --target web "tests/web_${suite}.gene" --out-dir dist >/dev/null
  gene run "$suite" > "$vm"
  node -e "import('./dist/web_${suite}.mjs').then(m => m.main())" > "$web"
  if diff "$vm" "$web" >/dev/null; then
    printf '%-10s cross-backend identical — %s\n' "$suite" "$(tail -1 "$vm")"
  else
    printf '%-10s DIVERGED\n' "$suite"
    diff "$vm" "$web"
    status=1
  fi
done
exit $status
