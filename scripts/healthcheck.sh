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
if curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1; then
  ok "Caddy /healthz (HTTP)"
else
  fail "Caddy /healthz (HTTP) 无法访问"
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 http://127.0.0.1/v2/ || true)"
case "$code" in
  200|401) ok "Docker Hub 缓存 /v2/  HTTP $code" ;;
  *) fail "Docker Hub 缓存 /v2/  HTTP ${code:-timeout}" ;;
esac

if [ "$HTTP_ONLY" != "true" ] && [ "$SITE_ADDRESS" != ":80" ]; then
  if curl -fsS "https://${SITE_ADDRESS}/healthz" >/dev/null 2>&1; then
    ok "https://${SITE_ADDRESS}/healthz 证书与站点正常"
  else
    fail "https://${SITE_ADDRESS}/healthz 失败（证书未签下来或 443 未放行）"
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
