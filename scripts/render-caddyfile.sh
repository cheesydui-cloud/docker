#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/caddy/Caddyfile"
if [ -f "$ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$ROOT/.env"
  set +a
fi
SITE_ADDRESS="${SITE_ADDRESS:-:80}"
DOMAIN="${DOMAIN:-}"
HTTP_ONLY="${HTTP_ONLY:-false}"

proxy_block() {
  backend="$1"
  cat <<EOF
	reverse_proxy ${backend}:5000 {
		flush_interval -1
		transport http {
			read_timeout 1h
			write_timeout 1h
			dial_timeout 30s
		}
	}
EOF
}

site_common() {
  cat <<'EOF'
	encode gzip zstd
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
	}

	handle /healthz {
		respond "ok" 200
	}

	handle /v2* {
EOF
  proxy_block registry-dockerhub
  cat <<'EOF'
	}

	handle {
		root * /usr/share/caddy
		file_server
	}
EOF
}

mkdir -p "$ROOT/caddy"

{
  if [ "$HTTP_ONLY" = "true" ] || [ "$SITE_ADDRESS" = ":80" ]; then
    cat <<'EOF'
{
	auto_https off
	admin off
}

:80 {
EOF
    site_common
    cat <<'EOF'
}

:5001 {
EOF
    proxy_block registry-ghcr
    cat <<'EOF'
}

:5002 {
EOF
    proxy_block registry-gcr
    cat <<'EOF'
}

:5003 {
EOF
    proxy_block registry-quay
    cat <<'EOF'
}

:5004 {
EOF
    proxy_block registry-k8s
    cat <<'EOF'
}

:5005 {
EOF
    proxy_block registry-nvcr
    cat <<'EOF'
}

:5006 {
EOF
    proxy_block registry-mcr
    echo "}"
  else
    cat <<EOF
{
	email ${ACME_EMAIL:-admin@example.com}
	admin off
}

${SITE_ADDRESS} {
EOF
    site_common
    echo "}"

    # 默认只给「加速站主机名」签证书，避免未解析的 ghcr/k8s 拖垮 Caddy。
    # 需要全部子域名时，在 .env 设 ENABLE_ALL_SUBDOMAINS=true
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
        backend="${pair##*:}"
        host="${name}.${DOMAIN}"
        if [ "$host" = "$SITE_ADDRESS" ]; then
          continue
        fi
        echo
        echo "${host} {"
        proxy_block "$backend"
        echo "}"
      done
    fi
  fi
} > "$OUT"

echo "已生成 $OUT"
