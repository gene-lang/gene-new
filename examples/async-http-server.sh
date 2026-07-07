#!/usr/bin/env bash
# Validate / benchmark harness for examples/async-http-server.gene.
#
#   ./examples/async-http-server.sh validate   # curl-based e2e checks
#   ./examples/async-http-server.sh bench      # ab-based concurrency proof
#
# validate starts the example server, exercises every endpoint plus the
# admission limits (413/404/504, redacted logging, parked-fiber concurrency),
# then stops it gracefully via POST /stop and checks the process drained.
#
# bench proves the Phase 1 claims with numbers: fast-path throughput, N
# parked (sleep 1000) handlers finishing in ~1s wall, and N async job
# offloads (POST /job?ms=1000) answering 202 in ~1s wall. Uses ApacheBench
# (ab, shipped with macOS) when available, otherwise a curl fan-out.
#
# Env: GENE_BIN (default bin/gene; built -d:release if missing),
#      PORT (default 8091 — must match the port in the example).

set -u
cd "$(dirname "$0")/.."

HOST=127.0.0.1
PORT=${PORT:-8091}
BASE="http://$HOST:$PORT"
GENE_BIN=${GENE_BIN:-bin/gene}
EXAMPLE=examples/async-http-server.gene
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gene-http-example.XXXXXX")
SERVER_PID=
PASS=0
FAIL=0

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

note() { printf '%s\n' "$*"; }

ok() { PASS=$((PASS + 1)); note "  ok   $1"; }

bad() { FAIL=$((FAIL + 1)); note "  FAIL $1${2:+ — $2}"; }

# check <label> <expected-status> <expected-body-grep|-> <curl args...>
check() {
  local label=$1 want_status=$2 want_body=$3
  shift 3
  local body_file="$WORK/body"
  local status
  status=$(curl -s -m 15 -o "$body_file" -w '%{http_code}' "$@")
  if [[ "$status" != "$want_status" ]]; then
    bad "$label" "status $status, wanted $want_status"
    return 1
  fi
  if [[ "$want_body" != "-" ]] && ! grep -qF -- "$want_body" "$body_file"; then
    bad "$label" "body '$(head -c 120 "$body_file")' missing '$want_body'"
    return 1
  fi
  ok "$label"
}

build_gene() {
  if [[ ! -x "$GENE_BIN" ]]; then
    note "building $GENE_BIN (release)..."
    nim c -d:release --path:src --hints:off -o:"$GENE_BIN" src/gene.nim ||
      { note "build failed"; exit 1; }
  fi
}

start_server() {
  if curl -s -m 2 -o /dev/null "$BASE/status"; then
    note "port $PORT already serving — stop that server first"
    exit 1
  fi
  "$GENE_BIN" run "$EXAMPLE" >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  local deadline=$(( $(now_ms) + 10000 ))
  until curl -s -m 2 -o /dev/null "$BASE/status"; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      note "server exited during startup:"
      cat "$WORK/server.log"
      exit 1
    fi
    if (( $(now_ms) > deadline )); then
      note "server did not become ready on $BASE"
      exit 1
    fi
    sleep 0.1
  done
}

stop_server() {
  curl -s -m 10 -o /dev/null -X POST "$BASE/stop" || true
  local deadline=$(( $(now_ms) + 10000 ))
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    if (( $(now_ms) > deadline )); then
      return 1
    fi
    sleep 0.1
  done
  SERVER_PID=
}

validate() {
  build_gene
  start_server
  note "validating $EXAMPLE on $BASE"

  # --- routing: manual entry, discovered routes, :param captures, 404s ---
  check "GET / serves the manual route entry"      200 "GET  /hits"    "$BASE/"
  check "GET /help serves a discovered route"      200 "POST /stop"    "$BASE/help"
  check "GET /nope answers 404 (route table)"      404 -               "$BASE/nope"
  check "POST /job/vp?ms=300 answers 202"          202 '"state":"running"' \
        -X POST "$BASE/job/vp?ms=300"
  check "GET /job/vp reads the :id capture"        200 '"id":"vp"'     "$BASE/job/vp"
  check "POST /job generates an id"                202 '"id":"job-'    -X POST "$BASE/job?ms=100"
  check "GET /job/missing maps JobNotFound to 404" 404 '"error":"no such job"' \
        "$BASE/job/missing"

  # --- handlers: body, params, counter ---
  check "POST /echo echoes the body"               200 "hello gene"    \
        --data "hello gene" "$BASE/echo"
  check "POST /counter adds body-int"              200 '"hits":'      \
        --data "5" "$BASE/counter"
  check "GET /hits reports the access-log counter" 200 '"hits":'      "$BASE/hits"

  # --- async offload: the named job completes in the background ---
  sleep 0.5
  check "background job reached state done"        200 '"state":"done"' "$BASE/job/vp"
  check "GET /jobs snapshot counts completions"    200 '"completed":'  "$BASE/jobs"

  # --- Phase 1 admission limits ---
  head -c 131072 /dev/zero | tr '\0' 'x' > "$WORK/big"
  check "128KiB body answers 413 (max-body-bytes)" 413 -               \
        --data-binary @"$WORK/big" "$BASE/echo"
  check "overlong handler answers 504 (timeout)"   504 -               \
        "$BASE/sleep?ms=3000"

  # --- Phase 1 concurrency: two parked 800ms sleeps finish in ~0.8s wall ---
  local t0 t1 elapsed
  t0=$(now_ms)
  curl -s -m 15 -o "$WORK/s1" "$BASE/sleep?ms=800" &
  local c1=$!
  curl -s -m 15 -o "$WORK/s2" "$BASE/sleep?ms=800" &
  local c2=$!
  wait "$c1" "$c2"
  t1=$(now_ms)
  elapsed=$((t1 - t0))
  if grep -qF '"slept_ms":800' "$WORK/s1" && \
     grep -qF '"slept_ms":800' "$WORK/s2" && (( elapsed < 1400 )); then
    ok "two parallel /sleep?ms=800 took ${elapsed}ms (parked fibers, not serial)"
  else
    bad "parallel /sleep?ms=800" "took ${elapsed}ms, wanted <1400ms"
  fi

  # --- Phase 3 logging: redaction and error records ---
  curl -s -m 5 -o /dev/null -H "Authorization: Bearer secret123" "$BASE/help"
  check "access-log redacts the authorization header" 200 '"authorization":"[redacted]"' \
        "$BASE/log"
  check "error-log recorded the JobNotFound failure"  200 '"panic":false' "$BASE/log"

  # --- Phase 1 metrics + graceful stop ---
  check "GET /status reports serving metrics"      200 '"serving":true' "$BASE/status"
  if stop_server; then
    ok "POST /stop drained and the process exited"
  else
    bad "POST /stop" "process still alive after 10s"
  fi

  note ""
  note "$PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]]
}

bench_ab() {
  local empty="$WORK/empty"
  : > "$empty"
  note ""
  note "--- fast path: GET /hits, 2000 requests, concurrency 50 ---"
  # -l: the json body grows with the counter; length variance is not a failure
  ab -q -l -n 2000 -c 50 "$BASE/hits" | grep -E \
    "Requests per second|Time per request.*mean\)|Failed requests"
  note ""
  bench_parked
  note ""
  note "--- async offload: POST /job?ms=1000, 40 requests, concurrency 20 ---"
  note "    (handlers answer 202 immediately; expect ~1s total, not 40s)"
  ab -q -l -n 40 -c 20 -p "$empty" -T text/plain "$BASE/job?ms=1000" | grep -E \
    "Time taken for tests|Requests per second|Failed requests"
}

bench_parked() {
  # curl fan-out rather than ab: ab's connection pacing splits N=C=20 into
  # waves and overstates this scenario by ~2x.
  note "--- parked fibers: GET /sleep?ms=1000, 20 in parallel ---"
  note "    (task-per-request: expect ~1s total, not 20s)"
  local t0 t1
  t0=$(now_ms)
  seq 1 20 | xargs -P 20 -I{} curl -s -m 15 -o /dev/null "$BASE/sleep?ms=1000"
  t1=$(now_ms)
  note "    20 parked handlers finished in $((t1 - t0))ms"
}

bench_curl() {
  note "(ab not found — using a curl fan-out; numbers are rougher)"
  local t0 t1
  note ""
  note "--- fast path: GET /hits, 500 requests, concurrency 50 ---"
  t0=$(now_ms)
  seq 1 500 | xargs -P 50 -I{} curl -s -o /dev/null "$BASE/hits"
  t1=$(now_ms)
  note "    500 requests in $((t1 - t0))ms"
  note ""
  note "--- parked fibers: GET /sleep?ms=1000, 20 in parallel ---"
  t0=$(now_ms)
  seq 1 20 | xargs -P 20 -I{} curl -s -m 15 -o /dev/null "$BASE/sleep?ms=1000"
  t1=$(now_ms)
  note "    20 parked handlers in $((t1 - t0))ms (task-per-request: ~1s, not 20s)"
  note ""
  note "--- async offload: POST /job?ms=1000, 40 requests, 20 in parallel ---"
  t0=$(now_ms)
  seq 1 40 | xargs -P 20 -I{} curl -s -o /dev/null -X POST "$BASE/job?ms=1000"
  t1=$(now_ms)
  note "    40 offloaded jobs answered in $((t1 - t0))ms (~1s, not 40s)"
}

bench() {
  build_gene
  note "tip: benchmark a release binary (nimble speedy) for honest numbers"
  start_server
  note "benchmarking $EXAMPLE on $BASE"
  # warm up the fast path
  seq 1 50 | xargs -P 10 -I{} curl -s -o /dev/null "$BASE/hits"
  if command -v ab >/dev/null 2>&1; then
    bench_ab
  else
    bench_curl
  fi
  note ""
  note "--- server-side view: GET /status ---"
  curl -s -m 5 "$BASE/status"; note ""
  stop_server || note "warning: server did not drain within 10s"
}

case "${1:-}" in
  validate) validate ;;
  bench)    bench ;;
  *)
    note "usage: $0 validate|bench"
    exit 2
    ;;
esac
