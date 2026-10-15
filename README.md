# omniroute-deploy

Reproducible deployment of a **patched [OmniRoute](https://github.com/diegosouzapw/OmniRoute)** (v3.8.51) gateway:
Docker Compose stack, 23 source patches, nginx config, and scripts to build the image and move state between servers.

This repo contains **no secrets and no data**. Credentials, provider keys, OAuth tokens and the database live in
`.env` and `data/`, which are git-ignored and moved separately (see *Migrating*).

## What's here

| Path | Purpose |
|---|---|
| `patches/` | Patches applied on top of upstream commit `152d951` (`release/v3.8.51`). `retired/` = patches upstream has since absorbed. |
| `scripts/build.sh` | Fetches pristine upstream, applies every patch, builds `omniroute:3.8.51-web-omni-src22`. |
| `docker-compose.yml` | OmniRoute + Redis + Qdrant (semantic memory) + local reranker sidecar. All ports on loopback. |
| `local-rerank/` | Offline cross-encoder reranker (runs inside the app image). |
| `cli-tools/` | `package.json` for the Qoder CLI provider (`npm ci` here). |
| `nginx/` | Reverse-proxy snippets: `/omni`, WebSocket, and the root-path asset/API re-prefixing the image needs. |
| `tools/verify-deploy.sh` | Post-deploy smoke test. |
| `tools/provider-icons/` | Provenance records for the added provider logos. |

## Fresh install

Requirements: Linux, Docker + Compose + buildx, git, nginx, **>= 16 GB RAM+swap and ~15 GB disk for the build** (the
resulting image is ~3 GB; runtime needs ~6 GB RAM, 2 CPUs).

```bash
git clone https://github.com/raju-rathod-buildup/omniroute-deploy.git && cd omniroute-deploy
./scripts/build.sh                       # 20-40 min
(cd cli-tools && npm ci)
cp .env.example .env && chmod 600 .env   # fill in secrets + your hostname
mkdir -p data && chown 1000:1000 data
docker compose up -d
```

Then install the nginx config: put `nginx/conf.d/*` in `/etc/nginx/conf.d/`, `nginx/snippets/*` in
`/etc/nginx/snippets/`, replace `YOUR_HOST`, and `include /etc/nginx/snippets/omniroute.conf;` inside the `server { }`
block that serves your hostname (with TLS). Reload nginx. The dashboard is at `https://YOUR_HOST/omni`.

Check it: `BASE=https://YOUR_HOST ./tools/verify-deploy.sh`

## Migrating an existing instance (keep all providers, combos, keys)

Providers, combos, API keys and memory are **not** in this repo. On the old server:

```bash
./scripts/export-state.sh                # briefly stops omniroute; writes omniroute-state-<date>.tgz (SECRETS)
scp omniroute-state-*.tgz newserver:omniroute-deploy/
```

On the new server, after `git clone` and `./scripts/build.sh`:

```bash
./scripts/import-state.sh omniroute-state-<date>.tgz
# edit .env: NEXT_PUBLIC_BASE_URL, LIVE_WS_* -> new hostname.  Keep JWT_SECRET / API_KEY_SECRET UNCHANGED.
docker compose up -d
```

Notes:
- `JWT_SECRET` and `API_KEY_SECRET` must be identical to the old server's, or stored credentials will not decrypt.
- Don't run old and new at the same time: OAuth providers rotate refresh tokens and the second instance invalidates the first.
- Some providers are IP-sensitive (free tiers capped per IP, web-cookie providers re-challenging a new IP). Re-test after the move.
- `OMNIROUTE_BASE_PATH=/omni` is compiled into the image; changing it means rebuilding with `OMNIROUTE_BASE_PATH=... ./scripts/build.sh`.
- The reranker is reached at `172.24.0.1:8790` (the compose network gateway, pinned in `docker-compose.yml`).

## Upgrading upstream

Edit `UPSTREAM_REF` in `scripts/build.sh`, run it, and resolve any patch conflicts (`git apply --3way`), then regenerate
the affected patch from the staged diff so the set stays canonical.

## Licence

OmniRoute is MIT-licensed, Copyright (c) 2026 diegosouzapw. The patches here are derivative changes to that work and are
offered under the same MIT terms.
