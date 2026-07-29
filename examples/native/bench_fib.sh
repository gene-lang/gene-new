#!/usr/bin/env bash
# Build fib.gene as a loadable AOT library and compare it against the VM.
#
#   examples/native/bench_fib.sh
#
# Unlike benchmarks/scripts/bench_fib_aot_c, which times compiled fib as a
# standalone binary, this measures a call from the VM across the AOT boundary
# into compiled code — what a Gene program actually experiences.
#
# Environment: CC, GENE (default bin/gene).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/build/native-example"

CC="${CC:-cc}"
GENE="${GENE:-$root/bin/gene}"

if [[ ! -x "$GENE" ]]; then
  echo "gene binary not found at $GENE" >&2
  echo "build it first:  nimble build   (or set GENE=/path/to/gene)" >&2
  exit 1
fi

echo "=== Gene AOT Boundary Benchmark ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S %A')"
echo "Git commit: $(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "C compiler: $("$CC" --version 2>&1 | head -n 1)"
echo

mkdir -p "$out"

echo "==> generating C from fib.gene"
"$GENE" compile --target c "$here/fib.gene" > "$out/fib.c"

echo "==> building loadable AOT library"
undefined_flag=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  undefined_flag="-undefined dynamic_lookup"
fi
# shellcheck disable=SC2086
"$CC" -std=c11 -O2 -DGENE_AOT_DYNAMIC_ENTRIES=1 -shared -fPIC $undefined_flag \
  "$out/fib.c" -o "$out/libfib.dylib"

echo "==> running benchmark"
echo
cd "$root"
"$GENE" run "$here/bench_fib.gene"
