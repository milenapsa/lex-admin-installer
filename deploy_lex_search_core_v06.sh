#!/usr/bin/env sh
set -eu

echo "LEX_SEARCH_CORE_V06_DEPLOY_START"

NET="${NET:-gateway-health_default}"
CADDY="${CADDY:-media-studio-caddy}"
SEARCH="${SEARCH:-homosapiens-lex-search}"
APP_DIR="/srv/lex-search-core-v06"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

apk add --no-cache curl python3 >/dev/null 2>&1 || true

echo "1) Preflight"
docker network inspect "$NET" >/dev/null
docker ps --format '{{.Names}}' | grep -qx "$CADDY"
mkdir -p "$APP_DIR" /tmp/lex-v06-backups

echo "2) Writing Lex Search Core v0.6 server"
cat > "$APP_DIR/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
import json, time, re, os, uuid

VERSION = "0.6.0-contract-core"
SERVICE = "lex-search-core"
STARTED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

SOURCES = [
    {"id":"cnj_datajud","name":"CNJ DataJud API Pública","status":"needs_secret_or_connector_validation","coverage":["processos","movimentos","metadados"],"risk":"A3/A4"},
    {"id":"lexml_sru","name":"LexML/SRU","status":"planned","coverage":["legislacao","normas"],"risk":"A2"},
    {"id":"dou_inlabs","name":"DOU/INLABS","status":"planned_credentials_required_when_applicable","coverage":["diarios","publicacoes"],"risk":"A3"},
    {"id":"stj_ckan","name":"STJ CKAN/Dados Abertos","status":"planned","coverage":["jurisprudencia","datasets"],"risk":"A2"},
    {"id":"stf_corte_aberta","name":"STF/Corte Aberta","status":"planned","coverage":["jurisprudencia","processos_publicos"],"risk":"A2"},
    {"id":"tse_dados_abertos","name":"TSE Dados Abertos","status":"planned","coverage":["datasets","jurisprudencia_eleitoral"],"risk":"A2"},
    {"id":"tribunais_datajud","name":"TJs/TRFs/TRTs via DataJud quando disponível","status":"planned_or_needs_secret","coverage":["processos","movimentos"],"risk":"A3/A4"},
    {"id":"diarios_oficiais","name":"Diários oficiais judiciais/executivos/administrativos","status":"planned","coverage":["publicacoes","monitoramento"],"risk":"A3"},
]

CAPABILITIES = [
    {"id":"sources.registry","endpoint":"GET /v1/sources/registry","status":"ok"},
    {"id":"search.global","endpoint":"POST /v1/search/global","status":"ok_contract_sources_planned"},
    {"id":"search.legislacao","endpoint":"POST /v1/search/legislacao","status":"ok_contract_sources_planned"},
    {"id":"search.jurisprudencia","endpoint":"POST /v1/search/jurisprudencia","status":"ok_contract_sources_planned"},
    {"id":"processos.search","endpoint":"POST /v1/processos/search","status":"contract_ready_no_invention"},
    {"id":"processos.get","endpoint":"GET /v1/processos/{numero_cnj}","status":"contract_ready_source_insufficient_until_connector"},
    {"id":"diarios.search","endpoint":"POST /v1/diarios/search","status":"contract_ready_sources_planned"},
    {"id":"watchlists.create","endpoint":"POST /v1/watchlists","status":"dry_run_contract_no_persistence"},
    {"id":"events.list","endpoint":"GET /v1/events","status":"contract_ready_empty_until_monitoring"},
    {"id":"refresh_jobs.create","endpoint":"POST /v1/refresh-jobs","status":"dry_run_contract_no_persistence"},
    {"id":"deadline_calculator","endpoint":"planned","status":"planned_human_review_required"},
    {"id":"risk_due_diligence","endpoint":"planned","status":"planned_human_review_required"},
]

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def base(status="ok", **kw):
    data = {
        "status": status,
        "service": SERVICE,
        "version": VERSION,
        "generated_at": now(),
        "human_review_required": True,
        "no_invention_policy": True,
    }
    data.update(kw)
    return data

def safe_query(obj):
    if isinstance(obj, dict):
        return obj.get("query") or obj.get("q") or obj.get("numero_cnj") or obj.get("term") or obj.get("nome") or obj.get("documento") or obj
    return obj

def planned_sources(kind):
    ids = {
        "legislacao": ["lexml_sru","dou_inlabs"],
        "jurisprudencia": ["stj_ckan","stf_corte_aberta","tse_dados_abertos","tribunais_datajud"],
        "processos": ["cnj_datajud","tribunais_datajud"],
        "diarios": ["dou_inlabs","diarios_oficiais"],
        "global": [s["id"] for s in SOURCES],
    }
    wanted = set(ids.get(kind, ids["global"]))
    return [s for s in SOURCES if s["id"] in wanted]

def cnj_like(s):
    return bool(re.search(r"\d{7}[-.]?\d{2}[.]?\d{4}[.]?\d[.]?\d{2}[.]?\d{4}", s or ""))

class Handler(BaseHTTPRequestHandler):
    server_version = "LexSearchCoreV06/0.6"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, code, payload):
        raw = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def read_body(self):
        length = int(self.headers.get("Content-Length","0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8", "ignore")
        try:
            return json.loads(raw) if raw.strip() else {}
        except Exception:
            return {"raw": raw}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Headers","Content-Type, X-Lex-API-Key, Authorization")
        self.send_header("Access-Control-Allow-Methods","GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ["/", "/health", "/ready", "/v1/health/search-core"]:
            return self.send_json(200, base("ok", started_at=STARTED_AT, capabilities=len(CAPABILITIES)))
        if path == "/v1/sources/registry":
            return self.send_json(200, base("ok", sources=SOURCES, capabilities=CAPABILITIES, limitations=[
                "Conectores reais ainda devem ser validados fonte a fonte.",
                "Credenciais e segredos ficam fora do chat.",
                "Sistemas autenticados exigem gate A4 e revisão humana."
            ]))
        if path == "/v1/events":
            return self.send_json(200, base("ok", query_or_input={}, events=[], evidence=[], limitations=["Monitoramento contínuo ainda não persiste eventos neste runtime."], write_executed=False))
        if path.startswith("/v1/processos/"):
            numero = path.split("/v1/processos/",1)[1].strip("/")
            if not numero:
                return self.send_json(400, base("error", error="numero_cnj_required"))
            status = "source_insufficient"
            if not cnj_like(numero):
                status = "source_insufficient"
            return self.send_json(200, base(status, query_or_input={"numero_cnj": numero}, sources=planned_sources("processos"), evidence=[], result=None, message="Contrato ativo. Conector real de processo ainda não confirmou dados; nada foi inventado."))
        return self.send_json(404, base("error", error="not_found", path=path))

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        q = safe_query(body)
        if path in ["/v1/search/global", "/v1/search", "/v1/search/"]:
            return self.send_json(200, base("ok", query_or_input=q, sources=planned_sources("global"), evidence=[], results=[], message="Busca global v0.6: contrato ativo com fontes planejadas; conectores reais serão ativados sem inventar resultado."))
        if path == "/v1/search/legislacao":
            return self.send_json(200, base("ok", query_or_input=q, sources=planned_sources("legislacao"), evidence=[], results=[], message="Legislação: LexML/SRU e DOU planejados/pendentes de conector real."))
        if path == "/v1/search/jurisprudencia":
            return self.send_json(200, base("ok", query_or_input=q, sources=planned_sources("jurisprudencia"), evidence=[], results=[], message="Jurisprudência: contrato ativo. Sem acórdão real validado, não há citação inventada."))
        if path in ["/v1/search/processos", "/v1/processos/search"]:
            return self.send_json(200, base("source_insufficient", query_or_input=q, sources=planned_sources("processos"), evidence=[], results=[], accepted_keys=["numero_cnj","cpf","cnpj","nome","oab","tribunal"], message="Consulta processual comercial iniciada como contrato seguro. Conector real ainda pendente/needs_secret."))
        if path in ["/v1/search/diarios", "/v1/diarios/search"]:
            return self.send_json(200, base("planned", query_or_input=q, sources=planned_sources("diarios"), evidence=[], results=[], message="Busca em diários preparada; coleta/indexação ampla ainda pendente."))
        if path == "/v1/watchlists":
            return self.send_json(202, base("planned", query_or_input=q, watchlist_id="dryrun-"+uuid.uuid4().hex[:12], write_executed=False, evidence=[], message="Watchlist recebida em contrato dry-run; persistência/eventos/webhooks ainda não ativados."))
        if path == "/v1/refresh-jobs":
            return self.send_json(202, base("planned", query_or_input=q, refresh_job_id="dryrun-"+uuid.uuid4().hex[:12], write_executed=False, evidence=[], message="Atualização sob demanda preparada em dry-run; nenhum robô real executado."))
        return self.send_json(404, base("error", error="not_found", path=path, query_or_input=q))

if __name__ == "__main__":
    port = int(os.getenv("PORT","8080"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"{SERVICE} {VERSION} listening on {port}", flush=True)
    httpd.serve_forever()
PY

echo "3) Replace search core container"
docker rm -f "$SEARCH" >/dev/null 2>&1 || true
docker run -d --name "$SEARCH" --restart unless-stopped --network "$NET" -v "$APP_DIR:/app:ro" -w /app python:3.12-alpine python server.py >/dev/null
sleep 4

echo "4) Attach search core to every Caddy network"
docker inspect "$CADDY" > /tmp/caddy.inspect.json
python3 - <<'PY' > /tmp/caddy.networks
import json
d=json.load(open('/tmp/caddy.inspect.json'))[0]
for n in d.get('NetworkSettings',{}).get('Networks',{}).keys():
    print(n)
PY
while IFS= read -r net; do
  [ -n "$net" ] || continue
  echo "CONNECT_NETWORK=$net"
  docker network connect "$net" "$SEARCH" >/dev/null 2>&1 || true
done < /tmp/caddy.networks

echo "5) Load runtime Caddy with Lex v0.6 routes"
docker cp "$CADDY:/etc/caddy/Caddyfile" "/tmp/Caddyfile.before-lex-v06-$STAMP" 2>/dev/null || true
cat > /tmp/Caddyfile.lexv06 <<'EOF'
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
    handle /v1/search* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/sources* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/processos* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/diarios* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/watchlists* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/events* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/refresh-jobs* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/health/search-core* {
        reverse_proxy homosapiens-lex-search:8080
    }
    handle /v1/datajud* {
        reverse_proxy homosapiens-lex-datajud:8080
    }
    handle /datajud* {
        reverse_proxy homosapiens-lex-datajud:8080
    }
    handle {
        reverse_proxy homosapiens-lex-api:8080
    }
}

homosapiens.id, www.homosapiens.id {
    reverse_proxy homosapiens-site:80
}
EOF

docker cp /tmp/Caddyfile.lexv06 "$CADDY:/etc/caddy/Caddyfile"
docker exec "$CADDY" caddy fmt --overwrite /etc/caddy/Caddyfile
docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
sleep 5

echo "6) Self-tests"
FIRST_NET="$(head -n 1 /tmp/caddy.networks)"
echo "TEST_SEARCH_HEALTH"
docker run --rm --network "$FIRST_NET" curlimages/curl:8.11.1 -fsS "http://$SEARCH:8080/v1/health/search-core" | head -c 220; echo
echo "TEST_SOURCES_REGISTRY_VIA_CADDY"
docker run --rm --network "$FIRST_NET" curlimages/curl:8.11.1 -ksS --connect-to lex.homosapiens.id:443:"$CADDY":443 -o /tmp/out -w 'HTTP=%{http_code} SIZE=%{size_download}\n' https://lex.homosapiens.id/v1/sources/registry || true
echo "TEST_PROCESS_SEARCH_VIA_CADDY"
docker run --rm --network "$FIRST_NET" curlimages/curl:8.11.1 -ksS --connect-to lex.homosapiens.id:443:"$CADDY":443 -H 'Content-Type: application/json' -d '{"nome":"teste seguro","dry_run":true}' -o /tmp/out2 -w 'HTTP=%{http_code} SIZE=%{size_download}\n' https://lex.homosapiens.id/v1/processos/search || true

echo "7) Containers"
docker ps --format 'CONTAINER={{.Names}} STATUS={{.Status}} PORTS={{.Ports}}' | grep -E 'homosapiens-lex-search|media-studio-caddy' || true

echo "LEX_SEARCH_CORE_V06_DEPLOY_OK"
