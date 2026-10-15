#!/usr/bin/env bash
# Build the patched OmniRoute image from pristine upstream + patches/.
# Needs: git, docker (buildx), ~16 GB RAM+swap, ~15 GB free disk, 20-40 min.
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=https://github.com/diegosouzapw/OmniRoute.git
UPSTREAM_REF=152d95108c9c3d557562311ffed63240a511eb31   # release/v3.8.51
IMAGE=${OMNIROUTE_IMAGE:-omniroute:3.8.51-web-omni-src22}
BASE_PATH=${OMNIROUTE_BASE_PATH:-/omni}

if [ ! -d src/.git ]; then
  git init -q src
  git -C src remote add origin "$UPSTREAM"
fi
git -C src fetch --depth 1 origin "$UPSTREAM_REF"
git -C src checkout -q --detach -f FETCH_HEAD
git -C src clean -fdxq -e node_modules

# Patches are canonical: pristine tree + every patch == what production runs.
for f in patches/00*.patch; do
  git -C src apply --3way --whitespace=nowarn "../$f" || { echo "PATCH FAILED: $f" >&2; exit 1; }
done
tar xzf patches/0011-provider-icons-assets.tar.gz -C src   # logos (code is in 0011-provider-icons.patch)

# A memory-capped builder avoids OOM-killing other containers on a shared host.
docker buildx inspect omnibuild >/dev/null 2>&1 || \
  docker buildx create --name omnibuild --driver docker-container \
    --driver-opt memory=8g --driver-opt memory-swap=24g --bootstrap

docker buildx build --builder omnibuild --target runner-web \
  --build-arg OMNIROUTE_BASE_PATH="$BASE_PATH" \
  -t "$IMAGE" --load --progress=plain src

docker buildx stop omnibuild || true   # keep the cache volume, free the RAM
echo "Built $IMAGE"
