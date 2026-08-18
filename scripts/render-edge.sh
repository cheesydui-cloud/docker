#!/usr/bin/env sh
# 仅直连模式使用：边缘 Caddy 对外签证书，反代到内部 router。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/caddy/Caddyfile.edge"
if [ -f "$ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$ROOT/.env"
  set +a
fi

SITE_ADDRESS="${SITE_ADDRESS:-:80}"
DOMAIN="${DOMAIN:-}"
PANEL_ADDRESS="${PANEL_ADDRESS:-}"
PANEL_PORT="${PANEL_PORT:-8088}"
if [ -z "$PANEL_ADDRESS" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "example.com" ]; then
  PANEL_ADDRESS="panel.${DOMAIN}"
fi

mkdir -p "$ROOT/caddy"

if [ "${SITE_ADDRESS}" = ":80" ] || [ -z "$SITE_ADDRESS" ]; then
  cat > "$OUT" <<'EOF'
{
	auto_https off
	admin off
}

:80 {
	reverse_proxy caddy:80 {
		flush_interval -1
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}
EOF
  echo "已生成 $OUT （无域名，仅 HTTP 边缘）"
  exit 0
fi

{
  cat <<EOF
{
	email ${ACME_EMAIL:-admin@example.com}
	admin off
}

${SITE_ADDRESS} {
		encode gzip zstd
		reverse_proxy caddy:80 {
			flush_interval -1
			header_up X-Forwarded-Proto {scheme}
			header_up X-Forwarded-Host {host}
			transport http {
				read_timeout 1h
				write_timeout 1h
				dial_timeout 30s
			}
		}
	}
EOF

  if [ -n "$PANEL_ADDRESS" ] && [ "$PANEL_ADDRESS" != "$SITE_ADDRESS" ]; then
    cat <<EOF

${PANEL_ADDRESS} {
		encode gzip zstd
		reverse_proxy host.docker.internal:${PANEL_PORT} {
			header_up X-Forwarded-Proto {scheme}
			header_up X-Forwarded-Host {host}
			header_up Host {host}
		}
	}
EOF
  fi

  if [ -n "$DOMAIN" ] && [ "${ENABLE_ALL_SUBDOMAINS:-false}" = "true" ]; then
    for pair in \
      "docker:registry-dockerhub" \
      "ghcr:registry-ghcr" \
      "gcr:registry-gcr" \
      "quay:registry-quay" \
      "k8s:registry-k8s" \
      "nvcr:registry-nvcr" \
      "mcr:registry-mcr"
    do
      name="${pair%%:*}"
      host="${name}.${DOMAIN}"
      [ "$host" = "$SITE_ADDRESS" ] && continue
      cat <<EOF

${host} {
	reverse_proxy caddy:80 {
		flush_interval -1
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
		transport http {
			read_timeout 1h
			write_timeout 1h
		}
	}
}
EOF
    done
  fi
} > "$OUT"

echo "已生成 $OUT （边缘 HTTPS → 内部 caddy:80）"
