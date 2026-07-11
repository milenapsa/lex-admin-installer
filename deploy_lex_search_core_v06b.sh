#!/usr/bin/env sh
set -eu

echo "LEX_UI_DEPLOY_V01_START"
NET="${NET:-gateway-health_default}"
CADDY="${CADDY:-media-studio-caddy}"
SEARCH="${SEARCH:-homosapiens-lex-search}"
UI="${UI:-homosapiens-lex-ui}"
VOL="${VOL:-homosapiens_lex_ui_content}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

apk add --no-cache curl >/dev/null 2>&1 || true

echo "1) Preflight"
docker network inspect "$NET" >/dev/null
docker ps --format '{{.Names}}' | grep -qx "$CADDY"
docker ps --format '{{.Names}}' | grep -qx "$SEARCH"

echo "2) Publish UI content"
docker volume create "$VOL" >/dev/null
docker run --rm -v "$VOL:/out" alpine:3.20 sh -c \
  "set -eu; apk add --no-cache wget >/dev/null; wget -qO /out/index.new.html https://raw.githubusercontent.com/milenapsa/lex-admin-installer/main/ui/index.html; test -s /out/index.new.html; [ ! -f /out/index.html ] || cp /out/index.html /out/index.backup-$STAMP.html; mv /out/index.new.html /out/index.html"

echo "3) Start UI container"
docker rm -f "$UI" >/dev/null 2>&1 || true
docker run -d --name "$UI" --restart unless-stopped --network "$NET" \
  -v "$VOL:/usr/share/nginx/html:ro" nginx:1.27-alpine >/dev/null

echo "4) Apply Caddy routing"
docker cp "$CADDY:/etc/caddy/Caddyfile" "/tmp/Caddyfile.before-lex-ui-$STAMP" 2>/dev/null || true
cat > /tmp/Caddyfile.lex-ui <<'EOF'
{
    email milena@peterle.adv.br
}
actions.homosapiens.id {
    reverse_proxy media-studio-api:8000
}
api.homosapiens.id, juridica.peterle.adv.br {
    reverse_proxy homosapiens-lex-api:8080
}
lex.homosapiens.id {
    handle /v1/search* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/sources* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/processos* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/diarios* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/watchlists* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/events* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/refresh-jobs* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/health/search-core* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/datajud* { reverse_proxy homosapiens-lex-datajud:8080 }
    handle /datajud* { reverse_proxy homosapiens-lex-datajud:8080 }
    handle /health { reverse_proxy homosapiens-lex-search:8080 }
    handle { reverse_proxy homosapiens-lex-ui:80 }
}
homosapiens.id, www.homosapiens.id {
    reverse_proxy homosapiens-site:80
}
EOF
docker cp /tmp/Caddyfile.lex-ui "$CADDY:/etc/caddy/Caddyfile.new"
docker exec "$CADDY" caddy fmt --overwrite /etc/caddy/Caddyfile.new
docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile
docker exec "$CADDY" sh -c 'cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup-lex-ui-v01 && mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile && caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'

sleep 4

echo "5) Post-tests"
docker run --rm --network "$NET" curlimages/curl:8.10.1 -fsS "http://$UI/" | grep -q 'Pesquise. Verifique.'
docker run --rm --network "$NET" curlimages/curl:8.10.1 -kfsS https://lex.homosapiens.id/ | grep -q 'Pesquise. Verifique.'
docker run --rm --network "$NET" curlimages/curl:8.10.1 -kfsS \
  -H 'Content-Type: application/json' \
  -d '{"query":"requisitos da tutela de urgencia no CPC","limit":3}' \
  https://lex.homosapiens.id/v1/search | grep -q '"query_or_input"'
docker run --rm --network "$NET" curlimages/curl:8.10.1 -kfsS \
  https://lex.homosapiens.id/health | grep -q '"status"'

docker ps --filter "name=$UI" --format 'CONTAINER={{.Names}} STATUS={{.Status}}'
echo "LEX_UI_DEPLOY_V01_OK"
