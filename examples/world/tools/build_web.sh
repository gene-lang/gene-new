#!/bin/sh
# Build every portable module for the web profile into dist/.
#
# The profile emits one flat output dir keyed by basename, so this list is the
# whole graph rather than a set of entry points — and a module deleted from the
# tree leaves its `dist/*.mjs` behind, where a `.mjs` harness importing it will
# keep passing off the stale artifact. `--clean` wipes dist/ first and is what
# to use after adding or removing a core module.
#
#   tools/build_web.sh            # incremental
#   tools/build_web.sh --clean    # after a module was added or removed
set -e
cd "$(dirname "$0")/.."
# Prefer this checkout: PATH may name a different Gene installation, or even
# use a relative `bin` entry which changes meaning after the cd above.
GENE_EXE=${GENE_EXE:-"$(pwd)/../../bin/gene"}
if ! command -v "$GENE_EXE" >/dev/null 2>&1; then
  echo "Gene executable not found: $GENE_EXE (build the checkout or set GENE_EXE)" >&2
  exit 1
fi

if [ "$1" = "--clean" ]; then
  rm -rf dist
fi
mkdir -p dist

MODULES="
core/exact core/world core/registry core/tiles core/texture core/shaders
core/content core/mods core/light core/mesh core/loaded core/raycast core/vec
mods/neighborhood/src/neighborhood
client/atlas client/render client/main
probes/world_spec probes/light_spec probes/loaded_spec probes/raycast_spec
probes/web_world_spec probes/web_light_spec probes/web_loaded_spec
probes/web_raycast_spec
"

for m in $MODULES; do
  if output=$("$GENE_EXE" build --target web "$m.gene" --out-dir dist); then
    :
  else
    echo "Failed to build $m.gene:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

echo "built $(echo $MODULES | wc -w | tr -d ' ') modules into dist/"
