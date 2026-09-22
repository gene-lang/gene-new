#!/bin/sh
# The Commons' whole suite, as one command.
#
#   tools/check.sh           # everything, about 10 minutes on an idle machine
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
# ## Servers
#
# Each network probe needs its own server on a world no other probe has played
# in: a probe digs, crafts and places, and a second probe in the same world
# fails for reasons that are not its own. Generating a world takes about a
# minute, so this generates one **pristine** world once, stops that server
# before any client connects, and gives each probe a fresh copy of it.
#
# Readiness is the port, never the log: the server's stdout is block-buffered
# into a file. A port that is already taken is refused rather than waited on —
# it would be another server's world.
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

PORT=8790                        # server/main.gene and net_main.gene's literal
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gene_world_check.XXXXXX")
passed=0
failed=0
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null
    wait "$server_pid" 2>/dev/null
  fi
}
trap cleanup EXIT
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

listening() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  else
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
  fi
}

# start_server ROOT LOG — boot `gene run server` on ROOT and wait for its port.
# The budget is wall-clock seconds: generation takes about a minute on an idle
# machine and several times that under load, and a poll loop's iteration count
# stretches with the load it is meant to measure.
START_BUDGET=${START_BUDGET:-600}
start_server() {
  if listening; then
    echo "  port $PORT is already taken; refusing to test another server's world" >&2
    return 1
  fi
  GENE_WORLD_ROOT="$1" "$GENE_EXE" run server >"$2" 2>&1 &
  server_pid=$!
  started=$(date +%s)
  until listening; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      wait "$server_pid" 2>/dev/null
      server_pid=""
      return 1
    fi
    if [ $(( $(date +%s) - started )) -ge "$START_BUDGET" ]; then
      echo "  server not listening after ${START_BUDGET}s" >&2
      stop_server
      return 1
    fi
    sleep 1
  done
}

stop_server() {
  [ -n "$server_pid" ] || return 0
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
  stopped=$(date +%s)
  while listening && [ $(( $(date +%s) - stopped )) -lt 30 ]; do
    sleep 1
  done
}

echo "gene/world check — logs in $WORK"

# --- VM ---------------------------------------------------------------------
echo "VM"
SPECS="world wire protocol inventory edit loaded physics light mapgen abm"
for s in $SPECS; do
  "$GENE_EXE" run "${s}_spec" >"$WORK/vm_$s.log" 2>&1
  verdict "${s}_spec" "$WORK/vm_$s.log" $?
done

"$GENE_EXE" run persistence create "$WORK/persistence" >"$WORK/persist_create.log" 2>&1
st=$?
"$GENE_EXE" run persistence verify "$WORK/persistence" >"$WORK/persist_verify.log" 2>&1
verdict "persistence create → verify (fresh process)" "$WORK/persist_verify.log" $((st + $?))

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

  echo "client smoke (real server, real WebSocket)"
  WORLD_SMOKE_WORLD="$WORK/smoke" WORLD_SMOKE_FRESH=1 \
    node tools/net_client_smoke.mjs >"$WORK/smoke.log" 2>&1
  if [ $? -eq 0 ]; then ok "net_client_smoke, fresh world"; else fail "net_client_smoke, fresh world" "$WORK/smoke.log"; fi
  WORLD_SMOKE_WORLD="$WORK/smoke" WORLD_SMOKE_RECOVERY=1 \
    node tools/net_client_smoke.mjs >"$WORK/smoke_recovery.log" 2>&1
  if [ $? -eq 0 ]; then ok "net_client_smoke, recovering a partial world"; else fail "net_client_smoke, recovering a partial world" "$WORK/smoke_recovery.log"; fi

  echo "network probes (one server per probe)"
  mkdir -p "$WORK/pristine"
  if start_server "$WORK/pristine" "$WORK/server_pristine.log"; then
    stop_server
    for p in web_net_probe web_tick_probe web_entity_probe web_chest_probe web_players_probe; do
      rm -rf "$WORK/world_$p"
      cp -R "$WORK/pristine" "$WORK/world_$p"
      if start_server "$WORK/world_$p" "$WORK/server_$p.log"; then
        node tools/web_spec.mjs "$p" >"$WORK/$p.log" 2>&1
        verdict "$p" "$WORK/$p.log" $?
        stop_server
      else
        fail "$p: server did not start" "$WORK/server_$p.log"
      fi
    done
  else
    fail "generate the pristine probe world" "$WORK/server_pristine.log"
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
