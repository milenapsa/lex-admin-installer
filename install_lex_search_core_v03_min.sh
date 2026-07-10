#!/usr/bin/env bash
set -Eeuo pipefail
set +x
echo LEX_SEARCH_CORE_V03_MIN_START
B=/root/lex-search-core
mkdir -p "$B"
cat > "$B/server.py" <<'PY'
import json,time,re
from http.server import BaseHTTPRequestHandler,HTTPServer
V="0.3.0-search-core"
SEC="/secrets/lex_api_keys"
ROUTES={"/v1/search/global","/v1/search/legislacao","/v1/search/jurisprudencia","/v1/search/processos-publicos","/v1/search/diarios","/v1/documentos/analisar","/v1/documentos/extrair-fatos","/v1/casos/montar-linha-do-tempo","/v1/casos/sugerir-buscas","/v1/veritas/fontes","/v1/veritas/aderencia"}
def ks():
  try:return [x.strip() for x in open(SEC).read().splitlines() if x.strip()]
  except Exception:return []
def auth(h):return h.get("X-Lex-API-Key","") in ks()
def out(s,c,o):
  b=json.dumps(o,ensure_ascii=False).encode();s.send_response(c);s.send_header("content-type","application/json; charset=utf-8");s.send_header("cache-control","no-store");s.send_header("content-length",str(len(b)));s.end_headers();s.wfile.write(b)
def body(s):
  n=int(s.headers.get("content-length","0") or 0);return json.loads(s.rfile.read(n).decode() or "{}") if n else {}
def text(o):
  for k in ["query","q","texto","source_text","draft","tese","tema","documento","content"]:
    if o.get(k): return str(o[k])
  return json.dumps(o,ensure_ascii=False)
def facts(t):
  return {"cnj":re.findall(r"\b\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}\b",t)[:10],"datas":re.findall(r"\b\d{1,2}/\d{1,2}/\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b",t)[:20],"valores":re.findall(r"\bR\$\s?[\d\.,]+",t)[:10],"keywords":list(dict.fromkeys(re.findall(r"[A-Za-zÀ-ÿ]{5,}",t.lower())))[:20]}
def resp(p,o):
  t=text(o)[:20000];return {"status":"ok","service":"lex-search-core","version":V,"route":p,"extraction":facts(t),"sources_planned":["CNJ/DataJud","LexML/SRU","DOU/INLABS","STJ CKAN","STF/Corte Aberta","TSE Dados Abertos","TJs/TRFs/TRTs/TREs via DataJud ou endpoints publicos"],"rules":["sem fonte sem citacao","nao inventar jurisprudencia","revisao humana obrigatoria","PJe/eproc/e-SAJ/Projudi/Gov/certificado exigem gate A4"],"human_review_required":1,"time":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
OPEN={"openapi":"3.1.0","info":{"title":"Lex Search Core","version":V},"servers":[{"url":"https://lex.homosapiens.id"}],"paths":{r:{"post":{"operationId":"lex"+re.sub('[^A-Za-z0-9]',' ',r).title().replace(' ',''),"summary":"Lex Search Core protected route"}} for r in ROUTES},"components":{"securitySchemes":{"LexApiKeyAuth":{"type":"apiKey","in":"header","name":"X-Lex-API-Key"}}}}
class H(BaseHTTPRequestHandler):
  def log_message(self,*a): pass
  def do_GET(s):
    p=s.path.split("?",1)[0]
    if p=="/health": return out(s,200,{"status":"ok","service":"lex-search-core","version":V})
    if p in ["/openapi.json","/schema.json"]: return out(s,200,OPEN)
    return out(s,404,{"error":"not_found","path":p})
  def do_POST(s):
    p=s.path.split("?",1)[0]
    if p not in ROUTES: return out(s,404,{"error":"not_found","path":p})
    if not auth(s.headers): return out(s,403,{"error":"invalid_api_key","service":"lex-search-core"})
    try:o=body(s)
    except Exception:return out(s,400,{"error":"invalid_json"})
    return out(s,200,resp(p,o))
HTTPServer(("0.0.0.0",8080),H).serve_forever()
PY

docker rm -f homosapiens-lex-search >/dev/null 2>&1 || true
docker run -d --name homosapiens-lex-search --restart unless-stopped --network gateway-health_default -p 8102:8080 -v "$B":/app:ro -v homosapiens_lex_secrets:/secrets:ro python:3.12-slim sh -lc 'python /app/server.py'
sleep 3
docker exec media-studio-caddy sh -lc "cp /etc/caddy/Caddyfile /tmp/Caddyfile.before-search-core-$(date -u +%Y%m%dT%H%M%SZ)"
docker exec -i media-studio-caddy sh -lc 'cat > /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && caddy reload --config /etc/caddy/Caddyfile' <<'CADDY'
{
    email milena@peterle.adv.br
}
actions.homosapiens.id {
    reverse_proxy media-studio-api:8000
}
api.homosapiens.id {
    handle_path /_ops/* { reverse_proxy homosapiens-ops-runner:8110 }
    handle /lex/admin { reverse_proxy homosapiens-lex-admin:8080 }
    handle_path /lex/admin/* { reverse_proxy homosapiens-lex-admin:8080 }
    handle /lex { redir /lex/health 308 }
    handle /lex/ { redir /lex/health 308 }
    handle_path /lex/* { reverse_proxy 76.13.226.21:8096 }
    reverse_proxy 76.13.226.21:8099
}
lex.homosapiens.id {
    handle /admin { reverse_proxy homosapiens-lex-admin:8080 }
    handle_path /admin/* { reverse_proxy homosapiens-lex-admin:8080 }
    handle /openapi.json { reverse_proxy homosapiens-lex-search:8080 }
    handle /schema.json { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/search/* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/documentos/* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/casos/* { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/veritas/fontes { reverse_proxy homosapiens-lex-search:8080 }
    handle /v1/veritas/aderencia { reverse_proxy homosapiens-lex-search:8080 }
    reverse_proxy 76.13.226.21:8096
}
juridica.peterle.adv.br {
    reverse_proxy 76.13.226.21:8088
}
CADDY
sleep 5
echo SELFTEST_PUBLIC
docker run --rm curlimages/curl:8.10.1 sh -lc 'curl -ksS -o /tmp/h -w "HEALTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/health; cat /tmp/h; echo; curl -ksS -o /tmp/n -w "NOAUTH_HTTP=%{http_code} SIZE=%{size_download}\n" -X POST https://lex.homosapiens.id/v1/search/global -H "content-type: application/json" -d "{\"query\":\"teste\"}"; cat /tmp/n; echo'
KEY="$(docker run --rm -v homosapiens_lex_secrets:/secrets:ro python:3.12-slim python -c 'import pathlib; p=pathlib.Path("/secrets/lex_api_keys"); print(p.read_text().splitlines()[0].strip() if p.exists() and p.read_text().splitlines() else "")')"
if [ -n "$KEY" ]; then docker run --rm -e K="$KEY" curlimages/curl:8.10.1 sh -lc 'curl -ksS -o /tmp/p -w "PROTECTED_HTTP=%{http_code} SIZE=%{size_download}\n" -X POST https://lex.homosapiens.id/v1/search/global -H "content-type: application/json" -H "X-Lex-API-Key: $K" -d "{\"query\":\"alimentos avoengos stj\"}"; head -c 900 /tmp/p; echo'; fi
unset KEY
echo LEX_SEARCH_CORE_V03_MIN_OK
