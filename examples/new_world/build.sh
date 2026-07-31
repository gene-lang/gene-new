#!/bin/sh
# Builds the game end to end:
#   assets  — tools/gen_atlas.mjs writes assets/tiles.png from a palette + hash
#   logic   — world.gene -> dist/ via the `web` profile (Gene -> TypeScript/ESM)
#   page    — page.gene -> index.html via gene/html + gene/css on the VM
#
# index.html and dist/ are generated; do not edit them.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
gene="$root/bin/gene"

node "$here/tools/gen_atlas.mjs"

"$gene" build --target web "$here/world.gene" --out-dir "$here/dist"
# `js/fn ^from` paths are emitted verbatim, so the host module has to sit next
# to the generated module rather than next to the source.
cp "$here/host.mjs" "$here/dist/host.mjs"

"$gene" run "$here/page.gene" > "$here/index.html"
echo "wrote $here/index.html"
