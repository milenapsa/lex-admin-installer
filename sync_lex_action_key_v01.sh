#!/usr/bin/env bash
set -Eeuo pipefail

echo "LEX_ACTION_KEY_SYNC_V01_START"

VOL="homosapiens_lex_secrets"
KEYFILE="/secrets/lex_api_keys"
BACKUP_NAME="lex_api_keys.backup.$(date -u +%Y%m%dT%H%M%SZ)"

command -v docker >/dev/null
docker volume inspect "$VOL" >/dev/null

NEWKEY="lex_$(python3 -<<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"

docker run --rm -v "$VOL:/secrets" python:3.12-slim sh -lc '
  set -Eeuo pipefail
  mkdir -p /secrets
  touch /secrets/lex_api_keys
  cp /secrets/lex_api_keys "/secrets/'
"$BACKUP_NAME"
"'"
  chmod 600 /secrets/lex_api_keys "/secrets/'"
"$BACKUP_NAME"
"'" || true
'

docker run --rm -v "$VOL:/secrets" -e NEWKEY="$NEWKEY" python:3.12-slim sh -lc '
  set -Eeuo pipefail
  touch /secrets/lex_api_keys
  grep -qxF "$NEWKEY" /secrets/lex_api_keys || printf "%s\n" "$NEWKEY" >> /secrets/lex_api_keys
  chmod 600 /secrets/lex_api_keys || true
'

echo "Reiniciando containers Lex para recarregar chaves aceitas..."
for c in homosapiens-lex-api homosapiens-lex-search homosapiens-lex-datajud; do
  if docker ps -a --format "{{.Names}}" | grep -qx "$c"; then
    docker restart "$c" >/dev/null || true
  fi
done

sleep 5

echo "Testando chave nova sem exibir no curl..."
curl -ksS -o /tmp/lex_key_health -w "LEX_HEALTH_WITH_NEW_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
  -H "X-Lex-API-Key: $NEWKEY" \
  https://lex.homosapiens.id/health || true
head -c 500 /tmp/lex_key_health || true
echo

curl -ksS -o /tmp/lex_key_search -w "LEX_SEARCH_WITH_NEW_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
  -X POST https://lex.homosapiens.id/v1/search/global \
  -H "content-type: application/json" \
  -H "X-Lex-API-Key: $NEWKEY" \
  -d '{"query":"alimentos avoengos","limit":5}' || true
head -c 900 /tmp/lex_key_search || true
echo

echo
echo "COPIE_APNAS_A_LINHA_ENTRE_AS_MARCAS_NO_CAMPO_CHAVE_API_DO_GPT_BUILDER"
echo "NAO_ENVIE_ESTA_CHAVE_NO_CHAT"
echo "LEX_ACTION_KEY_START"
printf "%s\n" "$NEWKEY"
echo "LEX_ACTION_KEY_END"
echo "BACKUP_FILE_IN_VOLUME=$BACKUP_NAME"
echo "LEX_ACTION_KEY_SYNC_V01_OK"
