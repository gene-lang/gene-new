#!/bin/sh
# The Commons' whole suite, as one command.
#
#   tools/check.sh           # everything, about two minutes
#   tools/check.sh --fast    # no server: VM + web specs and their diffs
#
# Every step prints `ok` or `FAIL`, and the script exits non-zero if any step
# failed. Logs go to a scratch directory, which is kept (and named) on
# failure and removed on success.
#
# ## What counts as a pass
#
# The Gene runners exit 0 whether or not their checks held; the verdict is the
# `PASS — …` / `FAIL — …` line they print last. So a Gene step passes when it
# exits 0, prints a line starting `PASS`, and prints none starting `FAIL`.
# The node smokes exit non-zero on failure and are judged by exit status.
#
# A cross-backend spec passes only if the VM and web-profile reports are also
# byte-identical — every `core/` module must behave the same on both.
#
# ## The world process
#
# `tools/commons_smoke.mjs` creates a throwaway world, starts `gene run world
# run` itself, and plays it over HTTP sign-in and the `gene.world.v1`
# WebSocket, including a `kill -9` and restart.
set -u
cd "$(dirname "$0")/.."

GENE_EXE=${GENE_EXE:-"$(pwd)/../../bin/gene"}
if ! command -v "$GENE_EXE" >/dev/null 2>&1; then
  echo "Gene executable not found: $GENE_EXE (build the checkout or set GENE_EXE)" >&2
  exit 2
fi
export GENE_EXE
export GENE="$GENE_EXE"          # net_client_smoke.mjs reads this name
if ! command -v node >/dev/null 2>&1; then
  echo "node not found" >&2
  exit 2
fi

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gene_world_check.XXXXXX")
passed=0
failed=0
trap 'exit 130' INT TERM

ok()   { passed=$((passed + 1)); echo "  ok    $1"; }
fail() { failed=$((failed + 1)); echo "  FAIL  $1${2:+   ($2)}"; }

# verdict LABEL LOG STATUS — the Gene-runner rule above.
verdict() {
  if [ "$3" -eq 0 ] && grep -q '^PASS' "$2" && ! grep -q '^FAIL' "$2"; then
    ok "$1"
  else
    fail "$1" "$2"
  fi
}

echo "gene/world check — logs in $WORK"

# --- VM ---------------------------------------------------------------------
echo "VM"
SPECS="world wire protocol inventory edit loaded physics light mapgen abm"
for s in $SPECS; do
  "$GENE_EXE" run "${s}_spec" >"$WORK/vm_$s.log" 2>&1
  verdict "${s}_spec" "$WORK/vm_$s.log" $?
done

"$GENE_EXE" run divergence >"$WORK/vm_divergence.log" 2>&1
if [ $? -eq 0 ]; then ok "divergence"; else fail "divergence" "$WORK/vm_divergence.log"; fi

# --- web profile ------------------------------------------------------------
echo "web"
if tools/build_web.sh --clean >"$WORK/build_web.log" 2>&1; then
  ok "$(tail -1 "$WORK/build_web.log")"
else
  fail "build_web.sh --clean" "$WORK/build_web.log"
  echo "  (web build failed; skipping everything that runs dist/)"
  FAST=2
fi

if [ "$FAST" -ne 2 ]; then
  for s in $SPECS; do
    node tools/web_spec.mjs "web_${s}_spec" >"$WORK/web_$s.log" 2>&1
    verdict "web_${s}_spec" "$WORK/web_$s.log" $?
    if cmp -s "$WORK/vm_$s.log" "$WORK/web_$s.log"; then
      ok "${s}_spec: VM and web reports identical"
    else
      fail "${s}_spec: VM and web reports differ" "$WORK/web_$s.log"
    fi
  done
  node tools/web_spec.mjs web_divergence >"$WORK/web_divergence.log" 2>&1
  if cmp -s "$WORK/vm_divergence.log" "$WORK/web_divergence.log"; then
    ok "divergence: VM and web checksums identical"
  else
    fail "divergence: VM and web checksums differ" "$WORK/web_divergence.log"
  fi
fi

# --- servers ----------------------------------------------------------------
if [ "$FAST" -eq 0 ]; then
  echo "VM budgets"
  "$GENE_EXE" run worldgen >"$WORK/worldgen.log" 2>&1
  verdict "worldgen (reading B is a documented expected-fail)" "$WORK/worldgen.log" $?
  "$GENE_EXE" run wire_bench >"$WORK/wire_bench.log" 2>&1
  if [ $? -eq 0 ]; then ok "wire_bench runs"; else fail "wire_bench" "$WORK/wire_bench.log"; fi

  echo "the Commons world process (Milestone 1)"
  COMMONS_SMOKE_PORT=${COMMONS_SMOKE_PORT:-8097} \
    node tools/commons_smoke.mjs >"$WORK/commons_smoke.log" 2>&1
  if [ $? -eq 0 ]; then ok "commons_smoke: $(grep -c '^  ok' "$WORK/commons_smoke.log") checks"; else fail "commons_smoke" "$WORK/commons_smoke.log"; fi
  CLIENT_SMOKE_PORT=${CLIENT_SMOKE_PORT:-8098} \
    node tools/client_smoke.mjs >"$WORK/client_smoke.log" 2>&1
  if [ $? -eq 0 ]; then ok "client_smoke: $(grep -c '^  ok' "$WORK/client_smoke.log") checks"; else fail "client_smoke" "$WORK/client_smoke.log"; fi

  # Milestone 2: networked Lives. The Life side's own specs (against an
  # in-memory world), then real Life processes attached to a real world.
  # Both need the genex/websocket native library; its absence is a failure
  # with the build command, never a silent skip (world.md F11).
  echo "networked Lives (Milestone 2)"
  REPO=$(cd ../.. && pwd)
  LIB="$REPO/src/genex/websocket/build/libgene_websocket.dylib"
  [ -f "$LIB" ] || LIB="$REPO/src/genex/websocket/build/libgene_websocket.so"
  if [ ! -f "$LIB" ]; then
    fail "genex/websocket native library" "build it: python3 src/genex/websocket/tools/build.py --pkg-config-path <curl with WebSocket>/lib/pkgconfig"
  else
    (cd "$REPO" && "$GENE_EXE" test --package-root examples/life \
      examples/life/tests/world_network_spec.gene examples/life/tests/delivery_spec.gene) \
      >"$WORK/life_network_specs.log" 2>&1
    if [ $? -eq 0 ] && grep -q ' 0 failed, 0 errors' "$WORK/life_network_specs.log"; then
      ok "Life network specs: $(grep -o '^[0-9]* passed' "$WORK/life_network_specs.log")"
    else
      fail "Life network specs" "$WORK/life_network_specs.log"
    fi
    LIFE_SMOKE_PORT=${LIFE_SMOKE_PORT:-8099} \
      node tools/life_smoke.mjs >"$WORK/life_smoke.log" 2>&1
    if [ $? -eq 0 ]; then ok "life_smoke: $(grep -c '^  ok' "$WORK/life_smoke.log") checks"; else fail "life_smoke" "$WORK/life_smoke.log"; fi
  fi
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  rm -rf "$WORK"
  exit 0
fi
echo "logs kept in $WORK"
exit 1
