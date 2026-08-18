#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PORT="${PANEL_PORT:-8088}"
UNIT_SRC="$ROOT/panel/docker-mirror-panel.service"
UNIT_DST=/etc/systemd/system/docker-mirror-panel.service

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 执行，以便注册 systemd 服务"
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3
  else
    echo "请先安装 python3"
    exit 1
  fi
}

if command -v systemctl >/dev/null 2>&1; then
  tmp="$(mktemp)"
  py="$(command -v python3)"
  sed -e "s|/opt/docker-mirror|$ROOT|g" \
      -e "s|/usr/bin/python3|$py|g" \
      -e "s|PANEL_PORT=8088|PANEL_PORT=$PORT|g" \
      "$UNIT_SRC" > "$tmp"
  mv "$tmp" "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable --now docker-mirror-panel
  echo "面板已用 systemd 启动"
else
  echo "没有 systemd，改为前台运行面板"
  exec env MIRROR_ROOT="$ROOT" PANEL_PORT="$PORT" python3 "$ROOT/panel/app.py"
fi

secret=""
i=0
while [ "$i" -lt 10 ]; do
  if [ -f "$ROOT/panel/.secret" ]; then
    secret="$(tr -d '\n' < "$ROOT/panel/.secret")"
    [ -n "$secret" ] && break
  fi
  i=$((i + 1))
  sleep 1
done

ip="$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "打开控制台： http://${ip:-<服务器IP>}:${PORT}/"
echo "面板密码：   ${secret:-（看 $ROOT/panel/.secret）}"
echo "安全组请放行 TCP ${PORT}，建议只对自己家里的 IP 开放。"
