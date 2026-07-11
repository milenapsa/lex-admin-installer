#!/usr/bin/env bash
set -Eeuo pipefail

echo "LEX_BUNDLE_V05_START"
BASE="https://raw.githubusercontent.com/milenapsa/lex-admin-installer/main"
LOG="/root/lex_bundle_v05_$(date -u +%Y%m%dT%H%M%SZ).log"

run_step() {
  local name="$1"
  local url="$2"
  local dest="/root/${name}.sh"
  echo
  echo "===== ${name} ====="
  curl -fsSL "$url" -o "$dest"
  bash "$dest"
}

echo "Alvo: homosapiens.id / lex.homosapiens.id"
echo "Log local: $LOG"
echo "Sem expor chave no chat. Se o sync gerar chave, copiar só no Builder."

{
  echo "1) Search Core v0.3/v0.3.1"
  run_step "install_lex_search_core_v03_min" "$BASE/install_lex_search_core_v03_min.sh"

  echo "2) DataJud Engine v0.4"
  run_step "install_lex_datajud_engine_v04" "$BASE/install_lex_datajud_engine_v04.sh"

  echo "3) Caddy fix DataJud v0.4.3"
  run_step "fix_lex_datajud_caddy_v043" "$BASE/fix_lex_datajud_caddy_v043.sh"

  echo "4) Sincronização/rotação segura da chave da Action Lex v0.2"
  run_step "sync_lex_action_key_v02" "$BASE/sync_lex_action_key_v02.sh"

  echo "5) Self-test final com a chave local mais recente"
  if [ -f /root/lex_action_key_current ]; then
    KEY="$(cat /root/lex_action_key_current | tr -d '\r\n')"
  else
    KEY="$(docker run --rm -v homosapiens_lex_secrets:/secrets:ro python:3.12-slim sh -lc 'tail -n 1 /secrets/lex_api_keys 2>/dev/null || true')"
  fi

  curl -ksS -o /tmp/lex_bundle_health -w "BUNDLE_HEALTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/health || true
  head -c 500 /tmp/lex_bundle_health || true; echo

  curl -ksS -o /tmp/lex_bundle_sources_noauth -w "BUNDLE_SOURCES_NOAUTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/v1/sources/registry || true
  head -c 500 /tmp/lex_bundle_sources_noauth || true; echo

  if [ -n "$KEY" ]; then
    curl -ksS -o /tmp/lex_bundle_sources -w "BUNDLE_SOURCES_WITH_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
      -H "X-Lex-API-Key: $KEY" \
      https://lex.homosapiens.id/v1/sources/registry || true
    head -c 900 /tmp/lex_bundle_sources || true; echo

    curl -ksS -o /tmp/lex_bundle_search -w "BUNDLE_SEARCH_WITH_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
      -X POST https://lex.homosapiens.id/v1/search/global \
      -H "content-type: application/json" \
      -H "X-Lex-API-Key: $KEY" \
      -d '{"query":"alimentos avoengos","limit":5}' || true
    head -c 1200 /tmp/lex_bundle_search || true; echo

    curl -ksS -o /tmp/lex_bundle_datajud -w "BUNDLE_DATAJUD_HEALTH_WITH_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
      -H "X-Lex-API-Key: $KEY" \
      https://lex.homosapiens.id/v1/datajud/health || true
    head -c 900 /tmp/lex_bundle_datajud || true; echo
  else
    echo "WARN_NO_LOCAL_LEX_KEY_FOR_PROTECTED_SELFTEST"
  fi

  echo "6) Containers relevantes"
  docker ps --format 'CONTAINER={{.Names}} STATUS={{.Status}} PORTS={{.Ports}}' | grep -E 'homosapiens-lex|media-studio-caddy' || true

  echo "LEX_BUNDLE_V05_OK"
} 2>&1 | tee "$LOG"
