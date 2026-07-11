#!/usr/bin/env sh
set -eu
echo "LEX_SEARCH_CORE_V07_PUBLIC_CONNECTORS_START"
NET="${NET:-gateway-health_default}"
CADDY="${CADDY:-media-studio-caddy}"
SEARCH="${SEARCH:-homosapiens-lex-search}"
APP_DIR="/srv/lex-search-core-v07"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$APP_DIR" /tmp/lex-v07-backups

cat > "$APP_DIR/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, quote
from urllib.request import Request, urlopen
import json, time, os

VERSION="0.7.0-public-connectors"
SERVICE="lex-search-core"
STARTED=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

SOURCES=[
 {"id":"stj_ckan","name":"STJ CKAN/Dados Abertos","status":"connected","coverage":["datasets","metadados públicos"],"risk":"A2","endpoint":"https://dadosabertos.web.stj.jus.br/api/3/action/package_search"},
 {"id":"tse_dados_abertos","name":"TSE Dados Abertos","status":"connected","coverage":["datasets","metadados públicos"],"risk":"A2","endpoint":"https://dadosabertos.tse.jus.br/api/3/action/package_search"},
 {"id":"lexml_sru","name":"LexML/SRU","status":"blocked_security_challenge","coverage":["legislação","normas"],"risk":"A2"},
 {"id":"stf_corte_aberta","name":"STF/Corte Aberta","status":"tls_validation_failed","coverage":["jurisprudência","processos públicos"],"risk":"A2"},
 {"id":"cnj_datajud","name":"CNJ DataJud API Pública","status":"secret_missing","coverage":["processos","movimentos","metadados"],"risk":"A3/A4"},
 {"id":"dou_inlabs","name":"DOU/INLABS","status":"credentials_missing","coverage":["diários","publicações"],"risk":"A3"},
 {"id":"diarios_oficiais","name":"Diários oficiais","status":"planned","coverage":["publicações","monitoramento"],"risk":"A3"},
]

def now():
 return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def base(status="ok", **kw):
 d={"status":status,"service":SERVICE,"version":VERSION,"generated_at":now(),"human_review_required":True,"no_invention_policy":True}
 d.update(kw); return d

def fetch_json(url, timeout=20):
 req=Request(url, headers={"User-Agent":"HomoSapiens-Lex/0.7 (+https://homosapiens.id)"})
 with urlopen(req, timeout=timeout) as r:
  return json.loads(r.read().decode("utf-8","replace"))

def ckan_search(source, endpoint, query, rows=5):
 try:
  data=fetch_json(endpoint+"?q="+quote(query)+"&rows="+str(rows))
  result=data.get("result",{})
  items=[]
  for x in result.get("results",[])[:rows]:
   items.append({
    "source_id":source,
    "title":x.get("title") or x.get("name"),
    "description":(x.get("notes") or "")[:800],
    "url":x.get("url") or ("https://dadosabertos.web.stj.jus.br/dataset/"+x.get("name","") if source=="stj_ckan" else "https://dadosabertos.tse.jus.br/dataset/"+x.get("name","")),
    "metadata_modified":x.get("metadata_modified"),
    "type":"dataset_catalog"
   })
  return {"ok":True,"count":result.get("count",len(items)),"items":items}
 except Exception as e:
  return {"ok":False,"error":type(e).__name__+": "+str(e)[:240],"items":[]}

def do_search(query, limit=5):
 connectors=[]
 results=[]
 evidence=[]
 for s in SOURCES:
  if s["id"]=="stj_ckan":
   r=ckan_search("stj_ckan",s["endpoint"],query,min(limit,10)); connectors.append({"source_id":"stj_ckan",**r}); results+=r["items"]
  elif s["id"]=="tse_dados_abertos":
   r=ckan_search("tse_dados_abertos",s["endpoint"],query,min(limit,10)); connectors.append({"source_id":"tse_dados_abertos",**r}); results+=r["items"]
 connected=[s for s in SOURCES if s["status"]=="connected"]
 for item in results:
  evidence.append({"source":item["source_id"],"title":item["title"],"url":item["url"],"kind":"official_open_data_catalog"})
 substantive=bool(results)
 message=("Foram consultados catálogos oficiais de dados abertos. Os itens retornados são metadados de datasets, não jurisprudência nem resposta jurídica conclusiva."
          if substantive else
          "Conectores públicos foram consultados, mas não retornaram material aderente. Nenhuma conclusão jurídica foi emitida.")
 return base("ok", query_or_input=query, sources=SOURCES, connected_sources=connected, connector_runs=connectors,
             evidence=evidence, results=results, answer=None, substantive_answer=False, message=message)

class H(BaseHTTPRequestHandler):
 server_version="LexSearchCore/0.7"
 def log_message(self, fmt,*args): print(fmt%args, flush=True)
 def sendj(self, code,obj):
  raw=json.dumps(obj,ensure_ascii=False,indent=2).encode()
  self.send_response(code); self.send_header("Content-Type","application/json; charset=utf-8")
  self.send_header("Cache-Control","no-store"); self.send_header("Access-Control-Allow-Origin","*")
  self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
 def body(self):
  n=int(self.headers.get("Content-Length","0") or 0)
  try:return json.loads(self.rfile.read(n).decode()) if n else {}
  except:return {}
 def do_OPTIONS(self):
  self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
  self.send_header("Access-Control-Allow-Headers","Content-Type, Authorization, X-Lex-API-Key")
  self.send_header("Access-Control-Allow-Methods","GET, POST, OPTIONS"); self.end_headers()
 def do_GET(self):
  p=urlparse(self.path).path
  if p in ["/","/health","/ready","/v1/health/search-core"]:
   return self.sendj(200,base("ok",started_at=STARTED,connected_sources=[s["id"] for s in SOURCES if s["status"]=="connected"]))
  if p=="/v1/sources/registry":
   return self.sendj(200,base("ok",sources=SOURCES,limitations=["STJ/TSE ativos apenas como catálogos oficiais de dados abertos.","DataJud e DOU dependem de segredo externo.","LexML bloqueado por desafio de segurança no acesso servidor.","STF pendente de validação TLS."]))
  return self.sendj(404,base("error",error="not_found",path=p))
 def do_POST(self):
  p=urlparse(self.path).path; b=self.body()
  q=b.get("query") or b.get("q") or b.get("term") or ""
  if p in ["/v1/search","/v1/search/","/v1/search/global","/v1/search/jurisprudencia","/v1/search/legislacao"]:
   if not str(q).strip(): return self.sendj(400,base("error",error="query_required"))
   return self.sendj(200,do_search(str(q),int(b.get("limit",5) or 5)))
  return self.sendj(404,base("error",error="not_found",path=p))

if __name__=="__main__":
 ThreadingHTTPServer(("0.0.0.0",8080),H).serve_forever()
PY

docker inspect "$SEARCH" >/tmp/lex-v07-backups/search-before-$STAMP.json 2>/dev/null || true
docker rm -f "$SEARCH" >/dev/null 2>&1 || true
docker run -d --name "$SEARCH" --restart unless-stopped --network "$NET" -v "$APP_DIR:/app:ro" -w /app python:3.12-alpine python server.py >/dev/null
sleep 4

echo "POST_TEST_HEALTH"
docker run --rm --network "$NET" curlimages/curl:8.10.1 -fsS "http://$SEARCH:8080/health" | grep -q '"version": "0.7.0-public-connectors"'
echo "POST_TEST_SOURCES"
docker run --rm --network "$NET" curlimages/curl:8.10.1 -fsS "http://$SEARCH:8080/v1/sources/registry" | grep -q '"status": "connected"'
echo "POST_TEST_SEARCH"
docker run --rm --network "$NET" curlimages/curl:8.10.1 -fsS -H 'Content-Type: application/json' -d '{"query":"jurisprudencia alimentos adolescente","limit":3}' "http://$SEARCH:8080/v1/search" | grep -q '"connector_runs"'
docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
echo "LEX_SEARCH_CORE_V07_PUBLIC_CONNECTORS_OK"
