#!/usr/bin/env bash
set -Eeuo pipefail

echo "LEX_ACTION_KEY_SYNC_V02_START"

VOL="homosapiens_lex_secrets"
KEYFILE="/secrets/lex_api_keys"

command -v docker >/dev/null
docker volume inspect "$VOL" >/dev/null

NEWKEY="lex_$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"

echo "1) Backup seguro do arquivo de chaves..."
docker run --rm -v "$VOL:/secrets" python:3.12-slim sh -c '
set -Eeuo pipefail
mkdir -p /secrets
touch /secrets/lex_api_keys
cp /secrets/lex_api_keys /secrets/lex_api_keys.backup.v02 || true
chmod 600 /secrets/lex_api_keys /secrets/lex_api_keys.backup.v02 || true
'

echo "2) Adicionando chave nova ao volume seguro..."
docker run --rm -v "$VOL:/secrets" -e NEWKEY="$NEWKEY" python:3.12-slim sh -c '
set -Eeuo pipefail
mkdir -p /secrets
touch /secrets/lex_api_keys
python3 - <<PY
import os
path="/secrets/lex_api_keys"
new=os.environ["NEWKEY"].strip()
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    keys=[line.strip() for line in f if line.strip()]
if new not in keys:
    keys.append(new)
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(keys) + "\n")
os.chmod(path, 0o600)
PY
'

echo "3) Reiniciando containers Lex para recarregar chaves..."
for c in homosapiens-lex-api homosapiens-lex-search homosapiens-lex-datajud; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    docker restart "$c" >/dev/null || true
  fi
done

sleep 8

echo "4) Testando health com a chave nova..."
curl -ksS -o /tmp/lex_key_health -w "LEX_HEALTH_WITH_NEW_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
  -H "X-Lex-API-Key: $NEWKEY" \
  https://lex.homosapiens.id/health || true
head -c 600 /tmp/lex_key_health || true
echo

echo "5) Testando search com a chave nova..."
curl -ksS -o /tmp/lex_key_search -w "LEX_SEARCH_WITH_NEW_KEY_HTTP=%{http_code} SIZE=%{size_download}\n" \
  -X POST https://lex.homosapiens.id/v1/search/global \
  -H "content-type: application/json" \
  -H "X-Lex-API-Key: $NEWKEY" \
  -d '{"query":"alimentos avoengos","limit":5}' || true
head -c 1000 /tmp/lex_key_search || true
echo

echo
echo "COPIE_APENAS_A_LINHA_ENTRE_AS_MARCAS_NO_CAMPO_CHAVE_API_DO_GPT_BUILDER"
echo "NAO_ENVIE_ESTA_CHAVE_NO_CHAT"
echo "LEX_ACTION_KEY_START"
printf '%s\n' "$NEWKEY"
echo "LEX_ACTION_KEY_END"
echo "BACKUP_FILE_IN_VOLUME=lex_api_keys.backup.v02"
echo "LEX_ACTION_KEY_SYNC_V02_OK"
