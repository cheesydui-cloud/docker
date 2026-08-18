#!/usr/bin/env sh
# 美国服务器一键部署 Docker 镜像加速站
#
# 先把 DNS 指到这台机器（A 记录）：
#   mirror / docker / ghcr / gcr / quay / k8s / nvcr / mcr
#   或一条泛域名 * 
#
# 然后执行：
#   curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/install.sh | sudo bash -s -- --domain example.com --email you@example.com
#
# 可选：
#   --hub-user NAME --hub-token TOKEN   Docker Hub 账号，强烈建议填
#   --dir /opt/docker-mirror            安装目录
#   --skip-dns                          跳过 DNS 检查（不推荐）
set -eu

REPO_URL="${REPO_URL:-https://github.com/cheesydui-cloud/docker.git}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/cheesydui-cloud/docker/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/docker-mirror}"
DOMAIN=""
SITE_HOST=""
ACME_EMAIL=""
HUB_USER=""
HUB_TOKEN=""
SKIP_DNS="false"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 执行，例如： sudo bash $0 --domain example.com --email you@example.com"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --site) SITE_HOST="${2:-}"; shift 2 ;;
    --email) ACME_EMAIL="${2:-}"; shift 2 ;;
    --hub-user) HUB_USER="${2:-}"; shift 2 ;;
    --hub-token) HUB_TOKEN="${2:-}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --skip-dns) SKIP_DNS="true"; shift ;;
    -h|--help) usage ;;
    *) die "未知参数：$1" ;;
  esac
done

need_root

if [ -z "$DOMAIN" ]; then
  printf "请输入主域名（例如 example.com，不要带 https://）： "
  read -r DOMAIN
fi
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||; s|/$||; s|^mirror\.||')"
[ -n "$DOMAIN" ] || die "域名不能为空"
[ "$DOMAIN" != "example.com" ] || die "请换成你自己的域名，不要用 example.com"

if [ -z "$SITE_HOST" ]; then
  SITE_HOST="mirror.${DOMAIN}"
fi
SITE_HOST="$(printf '%s' "$SITE_HOST" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||; s|/$||')"

if [ -z "$ACME_EMAIL" ]; then
  printf "请输入证书通知邮箱： "
  read -r ACME_EMAIL
fi
[ -n "$ACME_EMAIL" ] || die "邮箱不能为空"

if [ -z "$HUB_USER" ]; then
  printf "Docker Hub 用户名（可回车跳过，但容易被限流）： "
  read -r HUB_USER || true
fi
if [ -n "$HUB_USER" ] && [ -z "$HUB_TOKEN" ]; then
  printf "Docker Hub Access Token： "
  read -r HUB_TOKEN || true
fi

export DEBIAN_FRONTEND=noninteractive

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    die "不支持的系统，请先手动安装：$*"
  fi
}

log "检查基础命令"
for cmd in curl git; do
  command -v "$cmd" >/dev/null 2>&1 || install_pkg "$cmd"
done
command -v ca-certificates >/dev/null 2>&1 || true
if command -v apt-get >/dev/null 2>&1; then
  apt-get install -y ca-certificates curl git dnsutils || true
fi

log "安装 / 检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
command -v docker >/dev/null 2>&1 || die "Docker 安装失败"
if ! docker compose version >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin || true
  fi
fi
docker compose version >/dev/null 2>&1 || die "未找到 docker compose 插件"

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

log "放行 80 / 443"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
fi

log "获取代码到 $INSTALL_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch --depth 1 origin main
  git -C "$INSTALL_DIR" reset --hard origin/main
elif [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "目录已存在，跳过克隆"
else
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
chmod +x install.sh scripts/*.sh www/install.sh 2>/dev/null || true

log "写入 .env"
cat > .env <<EOF
SITE_ADDRESS=${SITE_HOST}
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
HTTP_ONLY=false
DOCKERHUB_USERNAME=${HUB_USER}
DOCKERHUB_PASSWORD=${HUB_TOKEN}
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=localhost,127.0.0.1,caddy,registry-dockerhub,registry-ghcr,registry-gcr,registry-quay,registry-k8s,registry-nvcr,registry-mcr
HTTP_PORT=80
HTTPS_PORT=443
EOF

if [ "$SKIP_DNS" != "true" ]; then
  log "检查 DNS 是否指向本机"
  sh scripts/check-dns.sh
fi

log "生成站点与 Caddy 配置"
sh scripts/render-site.sh
sh scripts/render-caddyfile.sh

log "启动服务"
docker compose pull
docker compose up -d

log "等待证书与健康检查"
sleep 5
tries=0
until [ "$tries" -ge 24 ]; do
  if curl -fsS "https://${SITE_HOST}/healthz" >/dev/null 2>&1; then
    break
  fi
  tries=$((tries + 1))
  sleep 5
done

sh scripts/healthcheck.sh || true
sh scripts/print-client-config.sh

echo
echo "=========================================="
echo "部署完成"
echo "主站： https://${SITE_HOST}/"
echo "国内机器一键接入："
echo "  curl -fsSL https://${SITE_HOST}/install.sh | sudo MIRROR=https://${SITE_HOST} sh"
echo "=========================================="
echo "如果浏览器打不开，看日志："
echo "  cd ${INSTALL_DIR} && docker compose logs -f caddy"
echo "常见原因：DNS 未生效、云厂商安全组没放行 80/443、邮箱/域名填错导致证书失败"
