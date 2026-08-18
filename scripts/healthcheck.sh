#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  . ./.env
  set +a
fi

SITE_ADDRESS="${SITE_ADDRESS:-:80}"
HTTP_ONLY="${HTTP_ONLY:-false}"

ok() { printf '  [OK]  %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS + 1)); }
FAILS=0

echo "== 容器状态 =="
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose ps
else
  echo "  本机没有 Docker，跳过容器检查"
fi

echo
echo "== 本地 / 站点健康检查 =="
HTTP_PORT="${HTTP_PORT:-5080}"
LOCAL="http://127.0.0.1:${HTTP_PORT}"
if curl -fsS "${LOCAL}/healthz" >/dev/null 2>&1; then
  ok "Caddy /healthz (${LOCAL})"
else
  fail "Caddy /healthz (${LOCAL}) 无法访问"
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "${LOCAL}/v2/" || true)"
case "$code" in
  200|401) ok "Docker Hub 缓存 /v2/  HTTP $code" ;;
  *) fail "Docker Hub 缓存 /v2/  HTTP ${code:-timeout}" ;;
esac

# 有真实主机名时必须验公网 HTTPS。挂在现有 Nginx 后面时 HTTP_ONLY=true，
# 但浏览器走的仍是 https://docker.xxx，不能只看 127.0.0.1:5080。
if [ "$SITE_ADDRESS" != ":80" ] && printf '%s' "$SITE_ADDRESS" | grep -q '\.'; then
  if curl -fsS "https://${SITE_ADDRESS}/healthz" >/dev/null 2>&1; then
    ok "https://${SITE_ADDRESS}/healthz 证书与站点正常"
  else
    fail "https://${SITE_ADDRESS}/healthz 失败（现有 Nginx/Caddy 未挂上本站，或证书未签下来）"
  fi
fi

echo
echo "== 上游连通性（美国服务器必须能访问） =="
for url in \
  https://registry-1.docker.io/v2/ \
  https://ghcr.io/v2/ \
  https://gcr.io/v2/ \
  https://quay.io/v2/ \
  https://registry.k8s.io/v2/ \
  https://nvcr.io/v2/ \
  https://mcr.microsoft.com/v2/
do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 -L "$url" || true)"
  case "$code" in
    200|401|403) ok "$url  HTTP $code" ;;
    *) fail "$url  HTTP ${code:-timeout}" ;;
  esac
done

echo
if [ "$FAILS" -gt 0 ]; then
  echo "有 ${FAILS} 项失败。证书问题先看： docker compose logs caddy --tail=80"
  echo "上游失败说明这台机器出不了网，不适合当加速站。"
  exit 1
fi
echo "健康检查通过。"
