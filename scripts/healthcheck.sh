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
HTTP_PORT="${HTTP_PORT:-5080}"
PANEL_ADDRESS="${PANEL_ADDRESS:-}"
PANEL_PORT="${PANEL_PORT:-8088}"

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
LOCAL="http://127.0.0.1:${HTTP_PORT}"
if curl -fsS "${LOCAL}/healthz" >/dev/null 2>&1; then
  ok "内部路由 /healthz (${LOCAL})"
else
  fail "内部路由 /healthz (${LOCAL}) 无法访问"
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-redirs 0 "${LOCAL}/v2/" || true)"
case "$code" in
  200|401) ok "Docker Hub 缓存 /v2/  HTTP $code" ;;
  301|302|307|308) fail "内部路由对 /v2/ 做了跳转 HTTP $code（会和边缘 HTTPS 打架）" ;;
  *) fail "Docker Hub 缓存 /v2/  HTTP ${code:-timeout}" ;;
esac

if curl -fsS --connect-timeout 3 "http://127.0.0.1:${PANEL_PORT}/healthz" >/dev/null 2>&1; then
  ok "本机面板 /healthz (:${PANEL_PORT})"
else
  echo "  [SKIP] 本机面板未启动"
fi
if [ -n "$PANEL_ADDRESS" ]; then
  pcode="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 --max-redirs 0 "https://${PANEL_ADDRESS}/healthz" || true)"
  if [ "$pcode" = "200" ]; then
    ok "https://${PANEL_ADDRESS}/healthz"
  else
    echo "  [SKIP] https://${PANEL_ADDRESS}/healthz HTTP ${pcode:-timeout}（DNS 未指过来时正常）"
  fi
fi

if [ "$SITE_ADDRESS" != ":80" ] && printf '%s' "$SITE_ADDRESS" | grep -q '\.'; then
  pub="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 --max-time 20 --max-redirs 0 "https://${SITE_ADDRESS}/healthz" || true)"
  if [ "$pub" = "200" ]; then
    ok "https://${SITE_ADDRESS}/healthz"
  elif [ "$pub" = "301" ] || [ "$pub" = "302" ] || [ "$pub" = "307" ] || [ "$pub" = "308" ]; then
    fail "https://${SITE_ADDRESS}/healthz 在跳转 HTTP $pub（边缘二次 301 或 Cloudflare 橙云）"
  else
    fail "https://${SITE_ADDRESS}/healthz 失败 HTTP ${pub:-timeout}"
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
  echo "有 ${FAILS} 项失败。"
  echo "内部路由看： docker compose logs caddy --tail=80"
  echo "直连边缘看： docker compose logs edge --tail=80"
  echo "Nginx 接入看： nginx -T 2>/dev/null | grep -n docker. -A2 | head"
  exit 1
fi
echo "健康检查通过。"
