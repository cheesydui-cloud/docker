#!/usr/bin/env sh
# 在「拉不到镜像的国内机器」上执行，把 Docker 指向加速站。
# 用法：
#   sudo MIRROR=https://mirror.example.com ./scripts/configure-client.sh
#   sudo MIRROR=http://10.0.0.8 ./scripts/configure-client.sh
set -eu

MIRROR="${MIRROR:-}"
if [ -z "$MIRROR" ]; then
  echo "请设置 MIRROR，例如："
  echo "  sudo MIRROR=https://mirror.example.com $0"
  echo "  sudo MIRROR=http://10.0.0.8 $0"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 执行（需要改 /etc/docker/daemon.json）"
  exit 1
fi

MIRROR="${MIRROR%/}"
DAEMON=/etc/docker/daemon.json
mkdir -p /etc/docker
BACKUP=""
if [ -f "$DAEMON" ]; then
  BACKUP="${DAEMON}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$DAEMON" "$BACKUP"
fi

python3 - "$MIRROR" "$DAEMON" <<'PY'
import json, sys
mirror, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except FileNotFoundError:
    data = {}
except Exception:
    data = {}

mirrors = data.get("registry-mirrors") or []
if not isinstance(mirrors, list):
    mirrors = []
if mirror not in mirrors:
    mirrors.insert(0, mirror)
data["registry-mirrors"] = mirrors

if mirror.startswith("http://"):
    host = mirror[len("http://"):]
    insecure = data.get("insecure-registries") or []
    if not isinstance(insecure, list):
        insecure = []
    extras = [host]
    if ":" not in host.split("/")[0]:
        extras.append(host + ":80")
        extras.append(host + ":5001")
        extras.append(host + ":5002")
        extras.append(host + ":5003")
        extras.append(host + ":5004")
        extras.append(host + ":5005")
        extras.append(host + ":5006")
    for item in extras:
        if item not in insecure:
            insecure.append(item)
    data["insecure-registries"] = insecure

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("已写入", path)
PY

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl restart docker
  echo "已重启 docker"
else
  echo "请手动重启 Docker 服务"
fi

echo
echo "验证："
echo "  docker info | grep -A5 'Registry Mirrors'"
echo "  docker pull nginx:alpine"
if [ -n "$BACKUP" ]; then
  echo "原配置备份：$BACKUP"
fi
