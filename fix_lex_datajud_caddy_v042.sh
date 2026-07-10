#!/usr/bin/env bash
set -Eeuo pipefail
set +x

echo "LEX_DATAJUD_CADDYFIX_V042_START"

docker ps --format '{{.Names}}' | grep -qx 'media-studio-caddy'
docker ps --format '{{.Names}}' | grep -qx 'homosapiens-lex-datajud'

docker exec media-studio-caddy sh -lc "cp /etc/caddy/Caddyfile /tmp/Caddyfile.before-datajud-v042-$(date -u +%Y%m%dT%H%M)) || true"

docker exec -i media-studio-caddy sh -lc 'cat > /etc/caddy/Caddyfile && caddy fmt --overwrite /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && caddy reload --config /etc/caddy/Caddyfile' <<'CADDY'
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

    handle_path /lex/v1/sources/* {
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

    handle_path /v1/datajud/* {
        reverse_proxy homosapiens-lex-datajud:8080
    }

    handle_path /v1/sources/* {
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

sleep 3

echo "SELFTEST_DATAJUD_CADDYFIX_V042"

curl -ksS -o /tmp/datajud_health -w "DATAJUD_HEALTH_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/v1/datajud/health
cat /tmp/datajud_health
echo

curl -ksS -o /tmp/source_registry -w "SOURCE_REGISTRY_HTTP=%{http_code} SIZE=%{size_download}\n" https://lex.homosapiens.id/v1/sources/registry
cat /tmp/source_registry
echo

curl -ksS -o /tmp/datajud_noauth -w "DATAJUD_NOAUTH_HTTP=%{http_code} SIZE=%{size_download}\n" "https://lex.homosapiens.id/v1/datajud/processos/0000000-00.0000.0.00.0000?tribunal=tjsc"
cat /tmp/datajud_noauth
echo

echo "CONTAINERS"
docker ps --format 'CONTAINER={{.Names}} STATUS={{.Status}} PORTS={{.Ports}}' | grep -E 'homosapiens-lex-datajud|homosapiens-lex-search|media-studio-caddy' || true

echo "LEX_DATAJUD_CADDYFIX_V042_OK"
