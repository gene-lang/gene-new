#!/usr/bin/env bash
# Build and run the typed_native SQLite example.
#
#   ./build.sh          build, then run
#   ./build.sh --build  build only
#
# Also runnable as `nimble native_example` from the repo root.

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

# Resolve the package-declared `sqlite` system dependency through the same
# normalized resolver that build derivations consume. Nothing here probes
# Homebrew, guesses a library name, or inherits PKG_CONFIG_PATH implicitly.
sqlite_cflags=()
sqlite_libs=()
while IFS=$'\t' read -r kind flag; do
  if [[ "$kind" == "C" ]]; then
    sqlite_cflags+=("$flag")
  elif [[ "$kind" == "L" ]]; then
    sqlite_libs+=("$flag")
  fi
done < <(cd "$root" && nim r --path:src --hints:off \
  tools/system_dependency_flags.nim "$here" sqlite)

mkdir -p "$out"

echo "==> generating C from sqlite_rows.gene"
"$GENE" compile --target c "$here/sqlite_rows.gene" > "$out/sqlite_rows.c"

echo "==> compiling"
"$CC" -std=c11 -O2 -Wall "${sqlite_cflags[@]}" \
  "$out/sqlite_rows.c" "$here/main.c" \
  -o "$out/sqlite_example" "${sqlite_libs[@]}"

echo "==> built $out/sqlite_example"

# The other direction: build scaled.gene as a loadable AOT library so Gene can
# call into it. The dynamic entry adapters are compiled in here (they are off
# by default), and the gene_ffi_* helpers they call resolve from the gene
# executable at dlopen time.
echo "==> generating C from scaled.gene"
"$GENE" compile --target c "$here/scaled.gene" > "$out/scaled.c"

echo "==> building loadable AOT library"
undefined_flag=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  undefined_flag="-undefined dynamic_lookup"
fi
# shellcheck disable=SC2086
"$CC" -std=c11 -O2 -DGENE_AOT_DYNAMIC_ENTRIES=1 -shared -fPIC $undefined_flag \
  "$out/scaled.c" -o "$out/libscaled.dylib"

echo "==> built $out/libscaled.dylib"

if [[ "${1:-}" != "--build" ]]; then
  echo "==> running (C calling Gene-compiled code)"
  "$out/sqlite_example"
  echo "==> running (Gene calling native code)"
  "$GENE" run "$here/call_from_gene.gene"
fi
