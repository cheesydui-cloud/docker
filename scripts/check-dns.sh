#!/usr/bin/env sh
# 检查加速站相关域名是否都解析到这台美国服务器
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

if [ -z "$DOMAIN" ] || [ -z "$SITE_ADDRESS" ] || [ "$SITE_ADDRESS" = ":80" ]; then
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
echo "需要解析到这台机器的记录："
echo

ok=0
fail=0
for name in \
  "$SITE_ADDRESS" \
  "docker.${DOMAIN}" \
  "ghcr.${DOMAIN}" \
  "gcr.${DOMAIN}" \
  "quay.${DOMAIN}" \
  "k8s.${DOMAIN}" \
  "nvcr.${DOMAIN}" \
  "mcr.${DOMAIN}"
do
  ip="$(lookup "$name")"
  if [ -z "$ip" ]; then
    printf '  [缺]  %-40s  未解析\n' "$name"
    fail=$((fail + 1))
  elif [ -n "$public_ip" ] && [ "$ip" != "$public_ip" ]; then
    printf '  [偏]  %-40s  %s  (不是本机 %s)\n' "$name" "$ip" "$public_ip"
    fail=$((fail + 1))
  else
    printf '  [OK]  %-40s  %s\n' "$name" "$ip"
    ok=$((ok + 1))
  fi
done

echo
echo "DNS 控制台请加 A 记录（值填美国服务器公网 IP）："
echo "  mirror / docker / ghcr / gcr / quay / k8s / nvcr / mcr"
echo "或者一条泛域名：  *   A   <美国服务器IP>"
echo "TTL 先设 60 秒，改完等生效再 ./scripts/deploy.sh"
echo
if [ "$fail" -gt 0 ]; then
  echo "还有 ${fail} 条未就绪。证书签发依赖这些域名先指向本机 80/443。"
  exit 1
fi
echo "DNS 已就绪（${ok} 条）。可以部署。"
