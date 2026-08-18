#!/usr/bin/env sh
# 美国服务器一键升级到仓库最新 release，并重新挂 Nginx / 证书。
# 保留 .env、data/、panel/.secret。
#
#   curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh | sudo bash
set -eu

REPO_URL="${REPO_URL:-https://github.com/cheesydui-cloud/docker.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/docker-mirror}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "请用 root 执行： curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh | sudo bash"
fi

command -v git >/dev/null 2>&1 || die "需要 git"
command -v docker >/dev/null 2>&1 || die "需要 docker"

if [ ! -d "$INSTALL_DIR/.git" ]; then
  die "找不到 $INSTALL_DIR/.git ，请先按 README 一键安装"
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

log "更新容器"
docker compose pull
docker compose up -d

log "重新写入 Nginx/Caddy 并处理证书"
sh scripts/adapt-host.sh integrate

if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/docker-mirror-panel.service ]; then
  PANEL_PORT="${PANEL_PORT:-8088}" sh scripts/start-panel.sh || systemctl restart docker-mirror-panel || true
fi

log "健康检查"
sh scripts/healthcheck.sh || true
sh scripts/print-client-config.sh || true

echo
echo "=========================================="
echo "升级完成：$(git describe --tags --always 2>/dev/null || echo unknown)"
echo "浏览器打开加速站主机名，应是镜像站说明页，不是其它面板。"
echo "然后再在群晖 / 国内机器填 https://你的加速站主机名"
echo "=========================================="
