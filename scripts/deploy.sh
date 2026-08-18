#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "已创建 .env"
  echo "请改成你的域名后再执行："
  echo "  SITE_ADDRESS=mirror.你的域名"
  echo "  DOMAIN=你的域名"
  echo "  ACME_EMAIL=你的邮箱"
  exit 1
fi

# shellcheck disable=SC1091
set -a
. ./.env
set +a

if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker，请先在美国服务器安装 Docker"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "未检测到 docker compose 插件"
  exit 1
fi

if [ "${HTTP_ONLY:-false}" != "true" ] && [ "${SITE_ADDRESS:-:80}" != ":80" ]; then
  if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "example.com" ] || [ "$SITE_ADDRESS" = "mirror.example.com" ]; then
    echo "请先把 .env 里的 example.com 改成你自己的域名，再部署。"
    exit 1
  fi
  echo "检查 DNS ..."
  if ! sh scripts/check-dns.sh; then
    echo
    echo "DNS 还没指到这台美国服务器。先改解析，再重新执行 $0"
    echo "需要放行入站 TCP 80 和 443，Caddy 才能签证书。"
    exit 1
  fi
fi

mkdir -p data/dockerhub data/ghcr data/gcr data/quay data/k8s data/nvcr data/mcr www
chmod +x install.sh scripts/*.sh www/install.sh
echo "探测 80/443 占用并自动选择直连或挂到现有反代..."
sh scripts/adapt-host.sh configure
# configure 可能改写了 .env
set -a
. ./.env
set +a
sh scripts/render-site.sh
sh scripts/render-caddyfile.sh

echo "正在启动镜像加速站..."
docker compose up -d
echo "把域名接到现有 Nginx/Caddy（如需要）并处理证书..."
sh scripts/adapt-host.sh integrate || true

echo
echo "服务已启动。"
if [ "${HTTP_ONLY:-false}" = "true" ] || [ "${SITE_ADDRESS:-:80}" = ":80" ]; then
  echo "HTTP 模式： http://<服务器IP>/"
else
  echo "主站 / Docker Hub：  https://${SITE_ADDRESS}/"
  echo "子域名："
  echo "  docker.${DOMAIN}"
  echo "  ghcr.${DOMAIN}   gcr.${DOMAIN}   quay.${DOMAIN}"
  echo "  k8s.${DOMAIN}    nvcr.${DOMAIN}  mcr.${DOMAIN}"
  echo
  sh scripts/print-client-config.sh
fi
echo
echo "状态： docker compose ps"
echo "日志： docker compose logs -f caddy --tail=80"
echo "自检： ./scripts/healthcheck.sh"
