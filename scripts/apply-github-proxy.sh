#!/usr/bin/env sh
# 按 .env 独立启停 GitHub 正向代理。不改 COMPOSE_PROFILES，不碰 80/443/7788。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  . ./.env
  set +a
fi

ENABLED="$(printf '%s' "${GITHUB_PROXY_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
PORT="${GITHUB_PROXY_PORT:-3128}"
ALLOW="${GITHUB_PROXY_ALLOW:-}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_on() {
  case "$1" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

case "$PORT" in
  ''|*[!0-9]*) fail "GITHUB_PROXY_PORT 必须是数字" ;;
esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  fail "GITHUB_PROXY_PORT 范围 1024-65535"
fi
case "$PORT" in
  80|443|7788|5080|5443|8088|22) fail "端口 $PORT 已被本机其它用途占用，换一个" ;;
esac

compose() {
  # 不要沿用 .env 里的 COMPOSE_PROFILES=direct，否则会把 edge 一起带上。
  env COMPOSE_PROFILES= docker compose --profile github-proxy "$@"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${PORT}/tcp" comment 'docker-mirror-github-proxy' >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

close_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

stop_proxy() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose stop github-proxy >/dev/null 2>&1 || true
    compose rm -f github-proxy >/dev/null 2>&1 || true
  fi
  close_firewall
  log "GitHub 代理已关闭"
}

if ! is_on "$ENABLED"; then
  stop_proxy
  exit 0
fi

allow_n=0
raw="$(printf '%s' "$ALLOW" | tr ',;' '  ' | tr '\n' ' ')"
for item in $raw; do
  case "$item" in
    ""|\#*) continue ;;
    0.0.0.0|0.0.0.0/0|::/0|\*|all)
      fail "不允许写成对全世界开放（$item）"
      ;;
  esac
  allow_n=$((allow_n + 1))
done
if [ "$allow_n" -eq 0 ]; then
  stop_proxy
  fail "已开启代理但没有允许 IP。先填国内机器公网 IP。"
fi

sh "${ROOT}/scripts/render-github-proxy.sh"
open_firewall
compose up -d github-proxy
log "GitHub 代理已启动 :${PORT}（tinyproxy Allow=${allow_n} 条）"
log "国内机器：export https_proxy=http://美国机IP:${PORT}"
