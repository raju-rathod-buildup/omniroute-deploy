#!/usr/bin/env bash
# Run on the NEW server, from the repo root, after ./scripts/build.sh.
#   ./scripts/import-state.sh omniroute-state-YYYY-MM-DD.tgz
set -euo pipefail
cd "$(dirname "$0")/.."
tar xzf "${1:?usage: import-state.sh <archive>}"
chmod 600 .env
chown -R 1000:1000 data                              # the container runs as uid 1000
docker volume create omniroute-qdrant-data >/dev/null
docker run --rm -v omniroute-qdrant-data:/d -v "$PWD":/in alpine tar xzf /in/.qdrant.tgz -C /d
rm -f .qdrant.tgz
echo "Restored. Edit .env for the new hostname, then: docker compose up -d"
