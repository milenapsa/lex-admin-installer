#!/usr/bin/env bash
set -Eeuo pipefail
set +x

echo "LEX_DATAJUD_ENGINE_V04_START"

B=/root/lex-datajud-engine
mkdir -p "$B"

cat > "$B/server.py" <<'PY'
import json, os, time, re, urllib.request, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

V = "0.4.0-datajud-engine"
SEC = "/secrets/lex_api_keys"
DATA_KEYS = ["/secrets/datajud_api_key", "/secrets/DATAJUD_API_KEY", "/run/secrets/datajud_api_key"]
ENDPOINTS = {
    "tjsc": "api_publica_tjsc", "tjrs": "api_publica_tjrs", "tjsp": "api_publica_tjsp",
    "tjrj": "api_publica_tjrj", "tjes": "api_publica_tjes",
    "trf1": "api_publica_trf1", "trf2": "api_publica_trf2", "trf3": "api_publica_trf3",
    "trf4": "api_publica_trf4", "trf5": "api_publica_trf5", "trf6": "api_publica_trf6",
    "stj": "api_publica_stj", "stf": "api_publica_stf", "tst": "api_publica_tst", "tse": "api_publica_tse",
}
def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def datajud_key():
    for p in DATA_KEYS:
        try:
            v = open(p).read().strip()
            if v: return v
        except Exception: pass
    return os.getenv("DATAJUD_API_KEY", "").strip()
def lex_keys():
    try: return [x.strip() for x in open(SEC).read().splitlines() if x.strip()]
    except Exception: return []
def lex_auth(headers): return headers.get("X-Lex-API-Key", "") in lex_keys()
def out(h, code, obj):
    b = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
    h.send_response(code); h.send_header("content-type","application/json; charset=utf-8")
    h.send_header("cache-control","no-store"); h.send_header("content-length",str(len(b)))
    h.end_headers(); h.wfile.write(b)
def clean_cnj(value):
    d = re.sub(r"\D", "", value or "")
    if len(d) != 20: return None
    return f"{d[0:7]}-{d[7:9]}.{d[9:13]}.{d[13]}.{d[14:16]}.{d[16:20]}"
def norm_tribunal(value):
    value = (value or "").lower().strip()
    return value if value in ENDPOINTS else ""
def source_registry():
    return [{
        "id": "cnj_datajud",
        "name": "CNJ DataJud API Pública",
        "kind": "process_metadata",
        "url": "https://datajud-wiki.cnj.jus.br/api-publica/",
        "status": "enabled" if datajud_key() else "needs_secret",
        "limitations": ["Metadados processuais; não substitui autos.", "Respeitar sigilo, termos de uso e revisão humana.", "A Lex não inventa andamento, prazo, resultado ou documento."]
    }]
def search_datajud(cnj, tribunal, size=1):
    key = datajud_key()
    if not key:
        return 503, {"status":"needs_datajud_secret","datajud_real":"not_configured","data":None,"sources":[],"warnings":["Configure a chave DataJud fora do chat.","A Lex não inventa andamento processual."],"human_review_required":1}
    normalized = clean_cnj(cnj)
    if not normalized:
        return 405, {"status":"invalid_cnj","data":None,"sources":[],"human_review_required":1}
    tribunal = norm_tribunal(tribunal) or "tjsc"
    endpoint = ENDPOINTS.get(tribunal)
    if not endpoint:
        return 405, {"status":"unsupported_tribunal","supported":sorted(ENDPOINTS),"human_review_required":1}
    url = f"https://api-publica.datajud.cnj.jus.br/{endpoint}/_search"
    payload = json.dumps({"query":{"match":{"numeroProcesso":{"query":re.sub(r"\D","",normalized)}}},"size":max(1,min(int(size or 1),25))}).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers={"Content-Type":"application/json","Authorization":"APIKey "+key}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read(500000).decode("utf-8", "ignore")
            parsed = json.loads(raw) if raw else {}
            return 200, {"status":"ok","datajud_real":"enabled","numero_cnj":normalized,"tribunal":tribunal,"endpoint":endpoint,"queried_at":now(),"sources":[{"id":"cnj_datajud","name":"CNJ DataJud API Pública","endpoint":endpoint,"url":"https://datajud-wiki.cnj.jus.br/api-publica/","accessed_at":now()}],"data":parsed,"limitations":["DataJud entrega metadados e não substitui autos do processo.","Respeitar sigilo, dados pessoais e termos de uso da fonte.","Revisão humana obrigatória antes de uso jurídico."],"human_review_required":1}
    except Exception as exc:
        return 502, {"status":"datajud_upstream_error","datajud_real":"error","error":exc.__class__.__name__,"message":str(exc)[:300],"sources":[{"id":"cnj_datajud","name":"CNJ DataJud API Pública","accessed_at":now()}],"human_review_required":1}
class H(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split("?",1)[0]
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if path == "/health":
            key = datajud_key()
            return out(self, 200, {"status":"ok","service":"lex-datajud","version":V,"source":"CNJ DataJud API Pública","datajud_real":"enabled" if key else "not_configured","query_endpoint":"enabled" if key else "disabled_until_secret_configured","secret_returned":0,"sources":source_registry(),"human_review_required":1})
        if path == "/sources/registry":
            return out(self, 200, {"status":"ok","sources":source_registry(),"human_review_required":1})
        if path.startswith("/processos/"):
            if not lex_auth(self.headers):
                return out(self, 403, {"error":"invalid_api_key","human_review_required":1})
            num = urllib.parse.unquote(path.split("/processos/",1)[1])
            tribunal = (qs.get("tribunal") or qs.get("orgao") or ["tjsc"])[0]
            size = int((qs.get("size") or ["1"])[0])
            code, body = search_datajud(num, tribunal, size)
            return out(self, code, body)
        return out(self, 404, {"error":"not_found","path":path})
HTTPServer(("0.0.0.0", 8080), H).serve_forever()
PY

docker rm -f homosapiens-lex-datajud >/dev/null 2>&1 || true
docker run -d --name homosapiens-lex-datajud --restart unless-stopped --network gateway-health_default -p 8100:8080 -v "$B":/app:ro -v homosapiens_lex_secrets:/secrets:ro python:3.12-slim sh -lc 'python /app/server.py'
sleep 3

docker exec media-studio-caddy sh -lc "cp /etc/caddy/Caddyfile /tmp/Caddyfile.before-datajud-v04-$(date -u +%Y%m%dT%H%M%SZ)"
docker exec -i media-studio-caddy sh -lc 'cat > /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && caddy reload --config /etc/caddy/Caddyfile' <<'CADDY'
{
    email milena@peterle.adv.br
}

actions.homosapiens.id {
    reverse_proxy media-studio-api:8000
}

api.homosapiens.id {
    handle_path /_ops/* {
        reverse_proxy homosapiens-ops-runner:8110
    }

    handle /lex/admin {
        reverse_proxy homosapiens-lex-admin:8080
    }

    handle_path /lex/admin/* {
        reverse_proxy homosapiens-lex-admin:8080
    }

    handle /lex {
        redir /lex/health 308
    }

    handle /lex/ {
        redir /lex/health 308
    }

    handle_path /lex/v1/datajud/* {
        reverse_proxy homosapiens-lex-datajud:8080
    }

    handle_path /lex/* {
        reverse_proxy 76.13.226.21:8096
    }

    reverse_proxy 76.13.226.21:8099
}

lex.homosapiens.id {
    handle /admin {
        reverse_proxy homosapiens-lex-admin:8080
    }

    handle_path /admin/* {
        reverse_proxy homosapiens-lex-admin:8080
    }

    handle /openapi.json {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /schema.json {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /v1/datajud/health {
        reverse_proxy homosapiens-lex-datajud:8080
    }

    handle_path /v1/datajud/* {
        reverse_proxy homosapiens-lex-datajud:8080
    }

    handle /v1/sources/registry {
        reverse_proxy homosapiens-lex-datajud:8080
    }

    handle /v1/search/* {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /v1/documentos/* {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /v1/casos/* {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /v1/veritas/fontes {
        reverse_proxy homosapiens-lex-search:8080
    }

    handle /v1/veritas/aderencia {
        reverse_proxy homosapiens-lex-search:8080
    }

    reverse_proxy 76.13.226.21:8096
}

juridica.peterle.adv.br {
    reverse_proxy 76.13.226.21:8088
}
CADDY

sleep 5
echo "SELFTEST_DATAJUD_V04"
docker run --rm curlimages/curl:8.10.1 sh -lc 'curl -ksS -o /tmp/h -w "DATAJUD_HEALTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/v1/datajud/health; cat /tmp/h; echo; curl -ksS -o /tmp/n -w "DATAJUD_NOAUTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/v1/datajud/processos/0000000-00.0000.0.00.0000?tribunal=tjsc; cat /tmp/n; echo'
echo "LEX_DATAJUD_ENGINE_V04_OK"
