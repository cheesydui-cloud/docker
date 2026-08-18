#!/usr/bin/env sh
# 内部路由器：永远 HTTP-only，禁止按 Host 跳转到 HTTPS。
# 对外证书由 edge 容器或宿主机 Nginx/Caddy 终止。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/caddy/Caddyfile"
if [ -f "$ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$ROOT/.env"
  set +a
fi

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

mkdir -p "$ROOT/caddy"

cat > "$OUT" <<'EOF'
{
	auto_https off
	admin off
}

:80 {
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
proxy_block registry-dockerhub >> "$OUT"
cat >> "$OUT" <<'EOF'
	}

	handle {
		root * /usr/share/caddy
		file_server
	}
}

:5001 {
EOF
proxy_block registry-ghcr >> "$OUT"
cat >> "$OUT" <<'EOF'
}

:5002 {
EOF
proxy_block registry-gcr >> "$OUT"
cat >> "$OUT" <<'EOF'
}

:5003 {
EOF
proxy_block registry-quay >> "$OUT"
cat >> "$OUT" <<'EOF'
}

:5004 {
EOF
proxy_block registry-k8s >> "$OUT"
cat >> "$OUT" <<'EOF'
}

:5005 {
EOF
proxy_block registry-nvcr >> "$OUT"
cat >> "$OUT" <<'EOF'
}

:5006 {
EOF
proxy_block registry-mcr >> "$OUT"
echo "}" >> "$OUT"

echo "已生成 $OUT （内部 HTTP 路由，auto_https off）"
