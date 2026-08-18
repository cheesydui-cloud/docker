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
