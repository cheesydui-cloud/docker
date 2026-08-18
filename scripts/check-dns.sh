#!/usr/bin/env sh
# 只强制检查「加速站主机名」。其余子域名有则报 OK，没有只警告。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "先复制并填写 .env： cp .env.example .env"
  exit 1
fi

# shellcheck disable=SC1091
set -a
. ./.env
set +a

DOMAIN="${DOMAIN:-}"
SITE_ADDRESS="${SITE_ADDRESS:-}"

if [ -z "$SITE_ADDRESS" ] || [ "$SITE_ADDRESS" = ":80" ]; then
  echo "当前是 HTTP/无域名模式，不用查 DNS。"
  exit 0
fi

lookup() {
  name="$1"
  out=""
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$name" | grep -E '^[0-9.]+$' | head -n1 || true)"
    if [ -z "$out" ]; then
      out="$(dig +short AAAA "$name" | head -n1 || true)"
    fi
  elif command -v nslookup >/dev/null 2>&1; then
    out="$(nslookup "$name" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1 || true)"
  fi
  printf '%s' "$out"
}

public_ip="$(curl -4 -fsS --connect-timeout 8 --max-time 15 https://ifconfig.me 2>/dev/null || true)"
if [ -z "$public_ip" ]; then
  public_ip="$(curl -4 -fsS --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
fi

echo "本机公网 IPv4：${public_ip:-未知}"
echo "必查（用来签证书的加速站主机名）："
echo

site_ip="$(lookup "$SITE_ADDRESS")"
if [ -z "$site_ip" ]; then
  printf '  [缺]  %-40s  未解析\n' "$SITE_ADDRESS"
  echo
  echo "请把 ${SITE_ADDRESS} 的 A 记录指到这台美国服务器 IP。"
  echo "Cloudflare 必须关闭橙色云（仅 DNS）。"
  exit 1
fi

if [ -n "$public_ip" ] && [ "$site_ip" != "$public_ip" ]; then
  printf '  [偏]  %-40s  %s  (不是本机 %s)\n' "$SITE_ADDRESS" "$site_ip" "$public_ip"
  echo
  echo "解析到了别的机器。确认 A 记录、关 Cloudflare 代理后再部署。"
  exit 1
fi

printf '  [OK]  %-40s  %s\n' "$SITE_ADDRESS" "$site_ip"

if [ -n "$DOMAIN" ]; then
  echo
  echo "可选子域名（没有也不影响 Docker Hub 加速）："
  for name in \
    "docker.${DOMAIN}" \
    "ghcr.${DOMAIN}" \
    "gcr.${DOMAIN}" \
    "quay.${DOMAIN}" \
    "k8s.${DOMAIN}" \
    "nvcr.${DOMAIN}" \
    "mcr.${DOMAIN}" \
    "mirror.${DOMAIN}" \
    "panel.${DOMAIN}"
  do
    [ "$name" = "$SITE_ADDRESS" ] && continue
    ip="$(lookup "$name")"
    if [ -z "$ip" ]; then
      printf '  [--]  %-40s  未解析（可以后再加）\n' "$name"
    elif [ -n "$public_ip" ] && [ "$ip" != "$public_ip" ]; then
      printf '  [偏]  %-40s  %s\n' "$name" "$ip"
    else
      printf '  [OK]  %-40s  %s\n' "$name" "$ip"
    fi
  done
fi

echo
if [ -n "${PANEL_ADDRESS:-}" ]; then
  echo
  echo "控制台域名（没有也不影响加速站）："
  pip="$(lookup "$PANEL_ADDRESS")"
  if [ -z "$pip" ]; then
    printf '  [--]  %-40s  未解析（解析后升级即可 https 打开后台）\n' "$PANEL_ADDRESS"
  elif [ -n "$public_ip" ] && [ "$pip" != "$public_ip" ]; then
    printf '  [偏]  %-40s  %s\n' "$PANEL_ADDRESS" "$pip"
  else
    printf '  [OK]  %-40s  %s\n' "$PANEL_ADDRESS" "$pip"
  fi
fi

echo
echo "主入口 DNS 已就绪，可以部署。"
echo "国内 / 群晖请填： https://${SITE_ADDRESS}"
