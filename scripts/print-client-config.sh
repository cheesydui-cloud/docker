#!/usr/bin/env sh
# 根据 .env 打印国内服务器该怎么配
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  . ./.env
  set +a
fi

SITE_ADDRESS="${SITE_ADDRESS:-mirror.example.com}"
DOMAIN="${DOMAIN:-example.com}"
MIRROR="https://${SITE_ADDRESS}"
GITHUB_PROXY_ENABLED="${GITHUB_PROXY_ENABLED:-false}"
GITHUB_PROXY_PORT="${GITHUB_PROXY_PORT:-3128}"
GITHUB_PROXY_ALLOW="${GITHUB_PROXY_ALLOW:-}"
PUBLIC_IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
  PUBLIC_IP="$(curl -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  case "$PUBLIC_IP" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
    *) PUBLIC_IP="" ;;
  esac
done
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="美国机IP"

cat <<EOF
======== 国内 Docker 客户端 ========

1) 一键：
   curl -fsSL ${MIRROR}/install.sh | sudo MIRROR=${MIRROR} sh

2) 或写入 /etc/docker/daemon.json ：
{
  "registry-mirrors": ["${MIRROR}"]
}

然后：
   sudo systemctl restart docker
   docker pull nginx:alpine

======== 其他仓库（改前缀） ========

  ghcr.io/xxx                 ->  docker pull ghcr.${DOMAIN}/xxx
  gcr.io/xxx                  ->  docker pull gcr.${DOMAIN}/xxx
  quay.io/xxx                 ->  docker pull quay.${DOMAIN}/xxx
  registry.k8s.io/xxx         ->  docker pull k8s.${DOMAIN}/xxx
  nvcr.io/xxx                 ->  docker pull nvcr.${DOMAIN}/xxx
  mcr.microsoft.com/xxx       ->  docker pull mcr.${DOMAIN}/xxx

例子：
  docker pull ghcr.${DOMAIN}/actions/runner:latest
  docker pull k8s.${DOMAIN}/pause:3.9

======== containerd hosts.toml ========

/etc/containerd/certs.d/docker.io/hosts.toml

server = "https://registry-1.docker.io"

[host."${MIRROR}"]
  capabilities = ["pull", "resolve"]
EOF

enabled="$(printf '%s' "$GITHUB_PROXY_ENABLED" | tr '[:upper:]' '[:lower:]')"
case "$enabled" in
  1|true|yes|on)
    cat <<EOF

======== 国内机访问 GitHub（正向代理） ========

在国内机器上执行一次：

  export http_proxy=http://${PUBLIC_IP}:${GITHUB_PROXY_PORT}
  export https_proxy=http://${PUBLIC_IP}:${GITHUB_PROXY_PORT}
  export no_proxy=localhost,127.0.0.1,${SITE_ADDRESS}

之后命令不用改：

  curl -fsSL https://raw.githubusercontent.com/user/repo/main/install.sh | bash
  git clone https://github.com/user/repo.git

允许的国内 IP： ${GITHUB_PROXY_ALLOW:-（未填）}
Docker 拉镜像不要走这个代理，继续用上面的加速站。
EOF
    ;;
  *)
    cat <<'EOF'

======== 国内机访问 GitHub ========

未开启。在控制台「系统设置」打开 GitHub 代理，并填国内机器公网 IP。
EOF
    ;;
esac
