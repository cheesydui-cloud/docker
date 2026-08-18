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
| `panel` | A | 同上（管理后台 `https://panel.你的域名`） |
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

### 方式 A：网页面板（推荐，域名在页面里填）

```bash
curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/install.sh \
  | sudo bash -s -- --panel
```

脚本只装 Docker、拉代码、启动控制台。然后：

1. 浏览器打开 `http://美国服务器IP:8088/`（或 DNS 生效后的 `https://panel.你的域名`）
2. 用终端打印的**面板密码**登录（也在 `/opt/docker-mirror/panel/.secret`）
3. 填写主域名、加速站主机名、证书邮箱、Docker Hub Token
4. 边缘接入可选：自动 / Nginx / Caddy / 直连
5. 点 **保存并部署**

安全组额外放行 **TCP 8088**（建议只给你自己的 IP）。控制台域名在面板里填，填了且 DNS 指到本机才会签证书。域名不会写死在代码里。

`http://IP:8088` 本身没有 HTTPS，Chrome 写「不安全」是正常的。群晖填你在面板里写的加速站主机名，不要填控制台地址。

### 任意机器怎么选边缘

缓存永远只听本机 `127.0.0.1:5080`，**内部不再签证书、不做 301**。  
面板选「自动」时按 80/443 占用决定；也可以强制 Nginx 或 Caddy：

| 这台机器的 80/443 | 自动做什么 |
| --- | --- |
| 都空闲 | 启动 `edge` 容器占 80/443，Caddy 签证书，反代到 5080 |
| Nginx / 3x-ui 自带 Nginx | 写 `/etc/nginx/conf.d/docker-mirror.conf`；把其它站点里同名 `server_name` 改掉（渡口/默认站不再抢走域名）；certbot 签证书 |
| 宿主机 Caddy | 把站点写入现有 Caddyfile，证书仍由那套 Caddy 签 |
| 其它进程 / 别人的容器 | 后端照常起来，日志打印要粘贴的片段，标明是谁占了 80，不乱改 |

空闲机器和占用机器用同一套安装命令。换一台机器再跑一遍即可，不用改参数。

群晖 / 国内 Docker 填面板里的加速站主机名。浏览器打开这个地址**没有网页**是正常的，它只给 Docker 拉镜像。说明和登录在控制台。

打开域名如果是 **另一个面板** 或浏览器报 `ERR_TOO_MANY_REDIRECTS`：跑升级命令。新版本 HTTP 不再 301 回自己，也不会让内部 Caddy 再跳 HTTPS。

### 已安装机器升级（保留缓存和面板密码）

```bash
curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh | sudo bash
```

这条永远拉最新 release：缺 git 会自动装，然后修 Nginx 证书、重新挂加速站主机名，不丢 `/opt/docker-mirror/data`。

### 方式 B：命令行一次填完

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

装好后群晖 / 国内机器填：`https://mirror.你的域名`  
浏览器打开这个地址**没有网站**，只会看到一行 `docker registry cache` 或 Registry 的 401，这是正常的。说明和配置在 `https://panel.你的域名`。

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
curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/docker/main/scripts/upgrade.sh | sudo bash
```

缓存目录：`/opt/docker-mirror/data/`（会变大，磁盘请预留）。

---

## 五、排错

| 现象 | 处理 |
| --- | --- |
| 一键脚本卡在 DNS | 解析还没指到这台机器，或 TTL 未生效 |
| 浏览器打开域名是别的项目 / 登录页 | 443 被原 Nginx 默认站抢走。升级后会改掉冲突 `server_name` |
| `ERR_TOO_MANY_REDIRECTS` / HTTP 308 | 边缘又 301 到 HTTPS，或 Cloudflare 开了橙云。新版本 HTTP 直接反代，不再跳转 |
| `toomanyrequests` | 加 `--hub-user` / `--hub-token` 后重跑或改 `.env` 再 `docker compose up -d` |
| 群晖填了还是很慢 / 失败 | 确认填的是 `https://mirror.域名`，并已重启套件 |
| `ghcr.io` / `k8s` 还是拉不到 | 正常，要改镜像前缀，不是只填加速地址 |
| 面板 `:8088` 显示「不安全」 | 正常。把 `panel` A 记录指到服务器后再升级，走 `https://panel.域名` |
| 面板按钮没反应 | 强制刷新控制台（Ctrl/Cmd+Shift+R）。结果在页面下方「操作结果」 |

这是**拉取缓存**，不是推送仓库，也不要裸奔成对全世界开放的公共镜像站（建议安全组只给自己用，或前面加防火墙）。
