#!/usr/bin/env sh
# 卸载本机的镜像加速站。不卸 Docker，不碰其它站点。
#
#   curl -fsSL "https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/uninstall.sh?$(date +%s)" | sudo bash
#
# 只停服务、留数据：
#   KEEP_DATA=1 curl -fsSL "https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/uninstall.sh?$(date +%s)" | sudo bash
set -eu

INSTALL_DIR="${INSTALL_DIR:-/opt/docker-mirror}"
KEEP_DATA="${KEEP_DATA:-0}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "请用 root 执行： curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/uninstall.sh | sudo bash"
fi

if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  log "停止容器"
  (cd "$INSTALL_DIR" && docker compose --profile github-proxy --profile direct down --remove-orphans) || \
    (cd "$INSTALL_DIR" && docker compose down --remove-orphans) || true
fi

if command -v systemctl >/dev/null 2>&1; then
  log "关闭控制台服务"
  systemctl disable --now docker-mirror-panel >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/docker-mirror-panel.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if [ -d /etc/nginx ]; then
  log "去掉本项目写入的 Nginx 站点"
  rm -f /etc/nginx/conf.d/docker-mirror.conf \
        /etc/nginx/conf.d/docker-mirror-panel.conf \
        /etc/nginx/sites-enabled/docker-mirror.conf \
        /etc/nginx/sites-enabled/docker-mirror-panel.conf
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && nginx -s reload || true
  fi
fi

if [ -f /etc/caddy/Caddyfile ]; then
  if grep -q 'BEGIN docker-mirror' /etc/caddy/Caddyfile 2>/dev/null; then
    log "去掉本项目写入的 Caddy 片段"
    tmp="$(mktemp)"
    awk '
      /# BEGIN docker-mirror/ {skip=1; next}
      /# END docker-mirror/ {skip=0; next}
      skip==0 {print}
    ' /etc/caddy/Caddyfile > "$tmp"
    mv "$tmp" /etc/caddy/Caddyfile
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload caddy >/dev/null 2>&1 || true
    fi
  fi
fi

if [ "$KEEP_DATA" = "1" ]; then
  log "已停服务。数据留在 $INSTALL_DIR"
else
  log "删除 $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
fi

echo
echo "=========================================="
echo "加速站已卸载。Docker 本身没有动。"
if [ "$KEEP_DATA" = "1" ]; then
  echo "缓存和配置还在：$INSTALL_DIR"
else
  echo "安装目录已删除。"
fi
echo "=========================================="
