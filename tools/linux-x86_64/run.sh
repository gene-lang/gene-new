#!/bin/sh
# Run a command against the tracked tree in a fresh linux/amd64 container.
#
#   tools/linux-x86_64/run.sh OUT_DIR [COMMAND]    (default COMMAND: nimble test)
#
# The container unpacks the tracked tree (HEAD plus uncommitted edits to
# tracked files, via `git stash create`) into /work; untracked files are not
# included and the checkout is never written. It runs detached; the log
# and exit status land in OUT_DIR/run.log, and OUT_DIR is mounted at /out for
# reports. On Apple silicon Docker runs the image under Rosetta, so timing
# gates measure emulation as well as the code.
set -eu
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$1"
out=$(cd "$1" && pwd)
shift
command=${1:-nimble test}
docker build --quiet --platform linux/amd64 -t gene-linux-x86_64 \
  "$root/tools/linux-x86_64" >/dev/null
snapshot=$(git -C "$root" stash create)
git -C "$root" archive --format=tar "${snapshot:-HEAD}" > "$out/src.tar"
{ git -C "$root" rev-parse HEAD
  if [ -n "$snapshot" ]; then echo "dirty: tracked edits in $snapshot"; fi
} > "$out/revision"
name="gene-linux-$(date +%Y%m%d%H%M%S)"
docker run -d --rm --name "$name" --platform linux/amd64 -v "$out:/out" \
  gene-linux-x86_64 sh -c '
    tar -xf /out/src.tar -C /work && cd /work &&
    { bash -c "$1"; } > /out/run.log 2>&1
    echo "exit=$?" >> /out/run.log' sh "$command" >/dev/null
echo "$name: tail -f $out/run.log"
