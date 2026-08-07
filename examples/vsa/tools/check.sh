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

# VM-only, so it is run rather than diffed: the web profile cannot enumerate a
# node's props, and its `match` type patterns are miscompiled (see
# src/codec/node.gene). A shell that could not run would be worse than none.
gene run node > "$vm"
if grep -q '^PASS' "$vm"; then
  printf '%-10s VM only          — %s\n' node "$(tail -1 "$vm")"
else
  printf '%-10s FAILED\n' node
  cat "$vm"
  status=1
fi

exit $status
