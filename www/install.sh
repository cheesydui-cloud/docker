#!/usr/bin/env sh
# 国内客户端一键配置。把下面的 MIRROR 换成你的加速站地址后执行：
#   curl -fsSL http://<加速站>/install.sh | sudo MIRROR=http://<加速站> sh
set -eu

MIRROR="${MIRROR:-}"
if [ -z "$MIRROR" ]; then
  echo "请设置 MIRROR，例如："
  echo "  curl -fsSL http://10.0.0.8/install.sh | sudo MIRROR=http://10.0.0.8 sh"
  echo "  curl -fsSL https://mirror.example.com/install.sh | sudo MIRROR=https://mirror.example.com sh"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 执行"
  exit 1
fi

MIRROR="${MIRROR%/}"
DAEMON=/etc/docker/daemon.json
mkdir -p /etc/docker
if [ -f "$DAEMON" ]; then
  cp "$DAEMON" "${DAEMON}.bak.$(date +%Y%m%d%H%M%S)"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 - "$MIRROR" "$DAEMON" <<'PY'
import json, sys
mirror, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
mirrors = [m for m in (data.get("registry-mirrors") or []) if isinstance(m, str)]
if mirror not in mirrors:
    mirrors.insert(0, mirror)
data["registry-mirrors"] = mirrors
if mirror.startswith("http://"):
    host = mirror[len("http://"):]
    insecure = [x for x in (data.get("insecure-registries") or []) if isinstance(x, str)]
    extras = [host]
    hostname = host.split("/")[0]
    if ":" not in hostname:
        extras += [f"{hostname}:{p}" for p in (80, 5001, 5002, 5003, 5004, 5005, 5006)]
    for item in extras:
        if item not in insecure:
            insecure.append(item)
    data["insecure-registries"] = insecure
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("已写入", path)
PY
else
  cat > "$DAEMON" <<EOF
{
  "registry-mirrors": ["${MIRROR}"]
}
EOF
  echo "未找到 python3，已覆盖写入最简 daemon.json"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl restart docker
  echo "已重启 docker"
else
  echo "请手动重启 Docker"
fi

echo "完成。执行： docker pull nginx:alpine"
