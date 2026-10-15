#!/usr/bin/env bash
# Post-deploy verification for omniroute. Run after any image cutover.
# Every check prints PASS/FAIL and the script exits non-zero if any check fails.
set -uo pipefail
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${BASE:-http://127.0.0.1:20128}"   # origin only; /omni is appended below by the checks
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "1. Containers healthy"
for c in omniroute omniroute-rerank omniroute-qdrant omniroute-redis; do
  s=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$s" = healthy ] && ok "$c: $s" || bad "$c: $s"
done
img=$(docker inspect --format '{{.Config.Image}}' omniroute 2>/dev/null)
ok "image: $img"

head_ "2. Version actually shipped"
v=$(docker exec omniroute node -e 'console.log(require("/app/package.json").version)' 2>/dev/null)
[ -n "$v" ] && ok "package.json version: $v" || bad "could not read version"

head_ "3. Auth boundary — must be 401, never 400/404"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4o-mini","messages":[]}' \
  $BASE/omni/api/v1/chat/completions)
[ "$code" = 401 ] && ok "unauthenticated /v1/chat/completions -> 401" \
                  || bad "unauthenticated /v1/chat/completions -> $code (expected 401)"

head_ "4. Rerank loopback URL resolves (patch 0006)"
# 401 = route found and auth-gated. 404 = the patch regressed and rerank is silently
# degrading retrieval to unranked order.
r=$(docker exec omniroute node -e '
const http=require("http");
const {dashboardPort}=(()=>{const p=parseInt(process.env.OMNIROUTE_PORT||process.env.PORT||"20128",10);
  return {dashboardPort:parseInt(process.env.DASHBOARD_PORT||String(p),10)};})();
const url=`${dashboardPort}${process.env.OMNIROUTE_BASE_PATH||""}/v1/rerank`;
const req=http.request({host:"127.0.0.1",port:dashboardPort,path:`${process.env.OMNIROUTE_BASE_PATH||""}/v1/rerank`,
  method:"POST",timeout:5000,headers:{"content-type":"application/json"}},
  res=>{console.log(res.statusCode+" "+url);process.exit(0);});
req.on("error",e=>{console.log("ERR "+e.code);process.exit(0);});
req.on("timeout",()=>{req.destroy();console.log("TIMEOUT");process.exit(0);});
req.end(JSON.stringify({model:"x",query:"q",documents:["a"]}));' 2>/dev/null)
case "$r" in
  401*|200*) ok "rerank loopback -> $r" ;;
  *)         bad "rerank loopback -> $r (404 means patch 0006 regressed)" ;;
esac

head_ "5. Memory embeddings still local, still landing in Qdrant"
q=$(curl -s http://127.0.0.1:6333/collections/omniroute_memory \
  | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r["config"]["params"]["vectors"]["size"],r["points_count"])' 2>/dev/null)
size=${q%% *}; pts=${q##* }
[ "$size" = 384 ] && ok "vector size 384 (local embeddings)" \
                  || bad "vector size $size (1536 = silently reverted to billed OpenAI embeddings)"
[ -n "$pts" ] && [ "$pts" -gt 0 ] 2>/dev/null && ok "points_count $pts" \
                  || bad "points_count $pts (0 means writes are failing quietly)"

head_ "6. Migrations applied cleanly"
n=$(docker logs omniroute 2>&1 | grep -ciE 'migration.*(fail|error)' )
[ "$n" = 0 ] && ok "no migration errors in logs" || bad "$n migration error lines in logs"
applied=$(sqlite3 $ROOT/data/storage.sqlite \
  "select count(*) from _omniroute_migrations;" 2>/dev/null)
highest=$(sqlite3 $ROOT/data/storage.sqlite \
  "select max(cast(version as integer)) from _omniroute_migrations;" 2>/dev/null)
# Every migration file the running image ships must have been applied — a shortfall
# means the runner stopped partway and the schema is behind the code.
shipped=$(docker exec omniroute sh -c 'ls /app/src/lib/db/migrations/*.sql 2>/dev/null | wc -l')
[ -z "$shipped" ] || [ "$shipped" = 0 ] && shipped=$(docker exec omniroute sh -c 'find /app -path "*/db/migrations/*.sql" 2>/dev/null | wc -l')
if [ -n "$applied" ] && [ -n "$shipped" ] && [ "$shipped" -gt 0 ] 2>/dev/null; then
  [ "$applied" -ge "$shipped" ] && ok "migrations: $applied applied (highest $highest), image ships $shipped" \
                                || bad "migrations: only $applied applied but image ships $shipped (highest $highest)"
elif [ -n "$applied" ]; then
  ok "migrations: $applied applied (highest $highest); could not count shipped files"
else
  bad "could not read migrations table"
fi

head_ "7. Provider icon assets serve (patch 0011)"
miss=0; checked=0
for f in agnes.png ainative.svg anyapi.png deepai.png nara.svg zai-web.svg; do
  checked=$((checked+1))
  c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/providers/$f")
  [ "$c" = 200 ] || { miss=$((miss+1)); echo "        $f -> $c"; }
done
[ "$miss" = 0 ] && ok "$checked sampled provider logos serve 200" \
               || bad "$miss/$checked sampled provider logos not serving"

head_ "8. Dashboard shell loads under /omni"
c=$(curl -s -o /dev/null -w '%{http_code}' $BASE/omni/dashboard)
case "$c" in 200|302|307) ok "/omni/dashboard -> $c" ;; *) bad "/omni/dashboard -> $c" ;; esac

head_ "9. Authenticated dashboard API (catches unbound-import regressions)"
# Added after the 3.8.51 cutover of 2026-09-12: checks 1-8 all passed while
# /api/models 500'd with "ReferenceError: resolveProviderAlias is not defined".
# Every check above is unauthenticated, so none of them ever executed that code.
PW=$(grep '^INITIAL_PASSWORD=' $ROOT/.env | cut -d= -f2-)
TOKEN=$(curl -s -D- -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "{\"password\":\"$PW\"}" $BASE/omni/api/auth/login \
  | grep -io 'auth_token=[^;]*' | head -1 | cut -d= -f2)
if [ -z "$TOKEN" ]; then bad "could not obtain a dashboard session"; else
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: auth_token=$TOKEN" $BASE/omni/api/models)
  [ "$c" = 200 ] && ok "/omni/api/models (session) -> 200" || bad "/omni/api/models (session) -> $c"
fi

head_ "10. Client API model catalog"
KEY=$(sqlite3 $ROOT/data/storage.sqlite \
  "select key from api_keys where is_active=1 and revoked_at is null and key like 'sk-%' limit 1;" 2>/dev/null)
if [ -z "$KEY" ]; then bad "no active API key available for the client-API check"; else
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" $BASE/omni/v1/models)
  [ "$c" = 200 ] && ok "/omni/v1/models (api key) -> 200" || bad "/omni/v1/models (api key) -> $c"

head_ "11. parseModel end-to-end (no upstream provider contacted)"
  # A deliberately unroutable provider/model. parseModel must parse it and the router
  # must fail cleanly on credentials — a 500 here means the model-resolution path threw.
  body=$(curl -s -w '\n%{http_code}' -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d '{"model":"zzz-not-a-provider/zzz-not-a-model","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
    $BASE/omni/v1/chat/completions)
  code=$(printf '%s' "$body" | tail -1)
  if [ "$code" = 500 ]; then bad "chat completions -> 500 (model resolution threw)"
  elif printf '%s' "$body" | grep -q 'zzz-not-a-provider'; then
    ok "chat completions -> $code, provider name parsed and echoed (parseModel intact)"
  else bad "chat completions -> $code but provider name absent from the error body"
  fi
fi

printf '\n'
[ "$FAIL" = 0 ] && printf '\033[32mALL CHECKS PASSED\033[0m\n' || printf '\033[31mSOME CHECKS FAILED\033[0m\n'
exit $FAIL
