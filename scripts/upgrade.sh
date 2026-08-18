#!/usr/bin/env sh
# 美国服务器一键升级到仓库最新 release，并重新挂 Nginx / 证书。
# 没装过也能跑：会装 git / Docker，拉代码，只起控制台。
# 保留已有 .env、data/、panel/.secret。
#
#   curl -fsSL "https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh?$(date +%s)" | sudo bash
set -eu

REPO_URL="${REPO_URL:-https://github.com/cheesydui-cloud/docker.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/docker-mirror}"
PANEL_PORT="${PANEL_PORT:-8088}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  else
    die "没有包管理器，请先手动安装：$*"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  log "安装 $1"
  install_pkg "$1"
  command -v "$1" >/dev/null 2>&1 || die "安装 $1 失败，请先执行：apt-get update && apt-get install -y $1"
}

if [ "$(id -u)" -ne 0 ]; then
  die "请用 root 执行： curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh | sudo bash"
fi

need_cmd git
need_cmd curl
if command -v apt-get >/dev/null 2>&1; then
  apt-get install -y ca-certificates >/dev/null 2>&1 || true
fi

if ! command -v docker >/dev/null 2>&1; then
  log "安装 Docker"
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

mkdir -p "$(dirname "$INSTALL_DIR")"
if [ ! -d "$INSTALL_DIR/.git" ]; then
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    die "$INSTALL_DIR 已有文件但不是 git 仓库，请先备份后删掉再跑，或改 INSTALL_DIR"
  fi
  log "本机还没装过，克隆仓库到 $INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  chmod +x install.sh scripts/*.sh www/install.sh 2>/dev/null || true
  if [ ! -f .env ]; then
    cp .env.example .env
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PANEL_PORT}/tcp" || true
  fi
  log "启动控制台。浏览器打开 http://本机IP:${PANEL_PORT}/ 填域名后再部署"
  PANEL_PORT="$PANEL_PORT" sh scripts/start-panel.sh
  exit 0
fi

cd "$INSTALL_DIR"
log "当前目录 $INSTALL_DIR"
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REPO_URL"
git remote set-url origin "$REPO_URL"

log "拉取最新代码和标签"
git fetch --tags --force --prune origin || true
git fetch --force origin main || git fetch --force origin master || true
# 浅克隆补全历史，避免 checkout 标签失败
git fetch --unshallow >/dev/null 2>&1 || true

TAG="$(git tag -l 'v*' --sort=-v:refname | head -n1 || true)"
if [ -n "$TAG" ]; then
  log "切换到 $TAG"
  git checkout -f "$TAG"
else
  log "没有版本标签，改用 origin/main"
  git checkout -f origin/main
fi

chmod +x install.sh scripts/*.sh www/install.sh 2>/dev/null || true

if [ ! -f .env ]; then
  die "没有 .env。打开面板重新填域名再部署，或先跑 install.sh"
fi

log "按当前 80/443 占用重新适配"
sh scripts/adapt-host.sh configure
sh scripts/render-site.sh
sh scripts/render-caddyfile.sh
sh scripts/render-edge.sh

log "更新容器"
	docker compose pull
	docker compose up -d

	log "按开关处理 GitHub 正向代理"
	sh scripts/apply-github-proxy.sh || true

log "重新写入 Nginx/Caddy 并处理证书"
sh scripts/adapt-host.sh integrate

log "重启控制台（必须，否则新接口不会生效）"
PANEL_PORT="${PANEL_PORT:-8088}" sh scripts/start-panel.sh || systemctl restart docker-mirror-panel || true

log "健康检查"
sh scripts/healthcheck.sh || true
sh scripts/print-client-config.sh || true

echo
echo "=========================================="
echo "升级完成：$(git describe --tags --always 2>/dev/null || echo unknown)"
echo "浏览器打开加速站主机名，应是镜像站说明页，不是其它面板。"
echo "然后再在群晖 / 国内机器填 https://你的加速站主机名"
echo "=========================================="
