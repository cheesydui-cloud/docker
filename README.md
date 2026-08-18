# Docker 镜像加速站

给**国内服务器 / 群晖**用的私有拉取缓存。  
部署在**美国（或任何能直连 Docker Hub 的）VPS** 上，国内机器只访问你的域名。

| 上游 | 国内怎么用 |
| --- | --- |
| Docker Hub（`nginx`、`mysql` 等） | 填 `registry-mirrors`，**镜像名不用改** |
| `ghcr.io` | `ghcr.你的域名/xxx` |
| `gcr.io` | `gcr.你的域名/xxx` |
| `quay.io` | `quay.你的域名/xxx` |
| `registry.k8s.io` | `k8s.你的域名/xxx` |
| `nvcr.io` | `nvcr.你的域名/xxx` |
| `mcr.microsoft.com` | `mcr.你的域名/xxx` |

仓库：<https://github.com/cheesydui-cloud/docker>

---

## 一、先做 DNS

在域名解析里，把下面记录都指到**美国服务器公网 IP**（A 记录）。  
Cloudflare 必须 **关闭小橙云（仅 DNS）**，否则证书和 Registry 会出问题。

| 主机记录 | 类型 | 值 |
| --- | --- | --- |
| `mirror` | A | 美国服务器 IP |
| `docker` | A | 同上 |
| `ghcr` | A | 同上 |
| `gcr` | A | 同上 |
| `quay` | A | 同上 |
| `k8s` | A | 同上 |
| `nvcr` | A | 同上 |
| `mcr` | A | 同上 |

或者一条泛域名：`*` → 美国服务器 IP。

云厂商安全组放行 **入站 TCP 80、443**。

---

## 二、美国服务器一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/install.sh \
  | sudo bash -s -- --domain 你的域名.com --email 你的邮箱@你的域名.com
```

建议同时带上 Docker Hub Token（否则匿名很容易 429）：

```bash
curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/install.sh \
  | sudo bash -s -- \
      --domain 你的域名.com \
      --email 你的邮箱@你的域名.com \
      --hub-user 你的DockerHub用户名 \
      --hub-token 你的AccessToken
```

脚本会自动：

1. 安装 Docker / Compose（没有的话）
2. 拉取本仓库到 `/opt/docker-mirror`
3. 检查 DNS 是否指向本机
4. 申请 Let's Encrypt 证书
5. 启动 7 个拉取缓存 + HTTPS 反代
6. 做健康检查并打印国内客户端配置

装好后打开：`https://mirror.你的域名/`

---

## 三、国内机器 / 群晖怎么用

### Linux 服务器

```bash
curl -fsSL https://mirror.你的域名/install.sh \
  | sudo MIRROR=https://mirror.你的域名 sh

docker info | grep -A6 'Registry Mirrors'
docker pull nginx:alpine
```

### 群晖

Container Manager（或 Docker）→ 设置 → Registry / 镜像加速，添加：

```text
https://mirror.你的域名
```

保存并重启套件。之后拉 `nginx`、`portainer/portainer-ce` 这类 Docker Hub 镜像即可。

### 其他仓库

`registry-mirrors` **只对 Docker Hub 生效**。例如：

```bash
# 原来
docker pull ghcr.io/actions/runner:latest
docker pull registry.k8s.io/pause:3.9

# 改成
docker pull ghcr.你的域名/actions/runner:latest
docker pull k8s.你的域名/pause:3.9
```

---

## 四、常用命令

```bash
cd /opt/docker-mirror
docker compose ps
docker compose logs -f caddy
./scripts/healthcheck.sh
./scripts/print-client-config.sh
docker compose pull && docker compose up -d
```

缓存目录：`/opt/docker-mirror/data/`（会变大，磁盘请预留）。

---

## 五、排错

| 现象 | 处理 |
| --- | --- |
| 一键脚本卡在 DNS | 解析还没指到这台机器，或 TTL 未生效 |
| 浏览器证书错误 / healthz 失败 | 安全组没放行 80/443，或 Cloudflare 开了代理 |
| `toomanyrequests` | 加 `--hub-user` / `--hub-token` 后重跑或改 `.env` 再 `docker compose up -d` |
| 群晖填了还是很慢 / 失败 | 确认填的是 `https://mirror.域名`，并已重启套件 |
| `ghcr.io` / `k8s` 还是拉不到 | 正常，要改镜像前缀，不是只填加速地址 |

这是**拉取缓存**，不是推送仓库，也不要裸奔成对全世界开放的公共镜像站（建议安全组只给自己用，或前面加防火墙）。
