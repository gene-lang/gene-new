#!/bin/sh
# Builds the game end to end:
#   assets  — tools/gen_atlas.mjs writes assets/tiles.png from a palette + hash
#   logic   — src/*.gene -> dist/ via the `web` profile (Gene -> TS/ESM)
#   page    — src/page.gene -> index.html via gene/html + gene/css on the VM
#
# index.html and dist/ are generated; do not edit them.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
gene="$root/bin/gene"

node "$here/tools/gen_atlas.mjs"

"$gene" build --target web "$here/src/world.gene" --out-dir "$here/dist"
"$gene" build --target web "$here/src/shell.gene" --out-dir "$here/dist"
"$gene" build --target web "$here/src/render.gene" --out-dir "$here/dist"
"$gene" build --target web "$here/src/main.gene" --out-dir "$here/dist"
"$gene" run "$here/src/page.gene" > "$here/index.html"
echo "wrote $here/index.html"
