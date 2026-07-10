#!/usr/bin/env bash
set -Eeuo pipefail
set +x

echo "LEX_SEARCH_CORE_V03_INSTALL_START"

BASE="/root/lex-search-core"
mkdir -p "$BASE"
cd "$BASE"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found. Run on the VPS terminal."
  exit 10
fi

if ! docker ps --format '{{.Names}}' | grep -xx 'media-studio-caddy'; then
  echo "ERROR: media-studio-caddy not running."
  docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'
  exit 11
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'homosapiens-lex-api'; then
  echo "ERROR: homosapiens-lex-api not running."
  docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'
  exit 12
fi

echo "1) Writing Lex Search Core server"
cat > "$BASE/server.py" <<'PY'
import json, os, time, re, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

V = "0.3.0-search-core"
SECRETS_FILE = "/secrets/lex_api_keys"

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def keys():
    try:
        return [x.strip() for x in open(SECRETS_FILE).read().splitlines() if x.strip()]
    except Exception:
        return []

def valid_key(headers):
    given = headers.get("X-Lex-API-Key", "")
    return bool(given and given in keys())

def read_body(handler):
    n = int(handler.headers.get("content-length", "0") or 0)
    raw = handler.rfile.read(n) if n else b"{}"
    return json.loads(raw.decode("utf-8") or "{}")

def send_json(handler, code, obj):
    data = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
    handler.send_response(code)
    handler.send_header("content-type", "application/json; charset=utf-8")
    handler.send_header("cache-control", "no-store")
    handler.send_header("content-length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

def extract_text(obj):
    for k in ("query", "q", "texto", "source_text", "draft", "tese", "tema", "documento", "content"):
        if obj.get(k):
            return str(obj.get(k))
    return json.dumps(obj, ensure_ascii=False)

def extract_facts(text):
    text = (text or "")[:20000]
    cnj = re.findall(r"\b\d{7}-\d{2}\.\d{4}\.\d\n??\.\0-1;,.?Roo oomited for considerate
#Ø