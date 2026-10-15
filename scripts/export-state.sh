#!/usr/bin/env bash
# Run on the OLD server. Writes ./omniroute-state-<date>.tgz with everything that is
# NOT in git: .env, data/ (SQLite, OAuth tokens, profiles) and the Qdrant volume.
# The archive contains SECRETS. Move it over scp/rsync; never commit or publish it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=omniroute-state-$(date +%F).tgz
docker compose stop omniroute                       # flush the SQLite WAL
trap 'docker compose start omniroute' EXIT
docker run --rm -v omniroute-qdrant-data:/d -v "$PWD":/out alpine tar czf /out/.qdrant.tgz -C /d .
tar czf "$OUT" .env data .qdrant.tgz
rm -f .qdrant.tgz
chmod 600 "$OUT"
echo "Wrote $OUT"
