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

mkdir -p "$ROOT/caddy"

proxy_block() {
  backend="$1"
  printf '\t\treverse_proxy %s:5000 {\n' "$backend"
  printf '\t\t\tflush_interval -1\n'
  printf '\t\t\ttransport http {\n'
  printf '\t\t\t\tread_timeout 1h\n'
  printf '\t\t\t\twrite_timeout 1h\n'
  printf '\t\t\t\tdial_timeout 30s\n'
  printf '\t\t\t}\n'
  printf '\t\t}\n'
}

{
  printf '%s\n' '{'
  printf '\tauto_https off\n'
  printf '\tadmin off\n'
  printf '%s\n' '}'
  printf '\n'
  printf '%s\n' ':80 {'
  printf '\tencode gzip zstd\n'
  printf '\theader {\n'
  printf '\t\tX-Content-Type-Options nosniff\n'
  printf '\t\tReferrer-Policy no-referrer\n'
  printf '\t}\n'
  printf '\n'
  printf '\thandle /healthz {\n'
  printf '\t\trespond "ok" 200\n'
  printf '\t}\n'
  printf '\n'
  printf '\thandle /v2* {\n'
  proxy_block registry-dockerhub
  printf '\t}\n'
  printf '\n'
  printf '\thandle /install.sh {\n'
  printf '\t\troot * /usr/share/caddy\n'
  printf '\t\trewrite * /install.sh\n'
  printf '\t\tfile_server\n'
  printf '\t}\n'
  printf '\n'
  printf '\t# 加速站没有网页。浏览器打开应是空白。\n'
  printf '\thandle {\n'
  printf '\t\trespond 204\n'
  printf '\t}\n'
  printf '%s\n' '}'
  printf '\n'

  for pair in \
    "5001:registry-ghcr" \
    "5002:registry-gcr" \
    "5003:registry-quay" \
    "5004:registry-k8s" \
    "5005:registry-nvcr" \
    "5006:registry-mcr"
  do
    port="${pair%%:*}"
    name="${pair#*:}"
    printf ':%s {\n' "$port"
    proxy_block "$name"
    printf '%s\n' '}'
    printf '\n'
  done
} > "$OUT"

echo "已生成 $OUT （内部 HTTP 路由，auto_https off）"
