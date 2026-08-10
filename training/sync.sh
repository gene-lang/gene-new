#!/usr/bin/env bash
# Push training/ (code, and the built corpus if present) to lenovo:~/exp/code/.
# Code lives in this repo; lenovo is where it runs and where models get
# downloaded (directly into ~/exp/models, not through this machine).
#
# Usage: training/sync.sh [remote_host] [remote_dir]
#   defaults: remote_host=lenovo  remote_dir=~/exp/code

set -euo pipefail

REMOTE_HOST="${1:-lenovo}"
REMOTE_DIR="${2:-~/exp/code}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

rsync -avz --delete \
  --exclude '.venv*' \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude 'checkpoints/' \
  "$SCRIPT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/training/"

echo "synced $SCRIPT_DIR -> $REMOTE_HOST:$REMOTE_DIR/training/"
echo "(corpus/ is included if it exists locally -- run build_corpus.py first" \
     "if you want a freshly built corpus on the remote side)"
