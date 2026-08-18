# 架构：任意机器同一套脚本

## 分层

```
客户端 / 群晖
    │  https://docker.你的域名
    ▼
边缘 TLS（三选一，脚本探测后自动选）
    ├─ 80/443 空闲      → compose profile `edge`（Caddy 签证书）
    ├─ 已有 Nginx/3x-ui → /etc/nginx/conf.d/docker-mirror.conf + certbot
    └─ 已有宿主机 Caddy → 写入现有 Caddyfile
    │
    │  可选：面板填写的控制台域名 → 127.0.0.1:8088
    │
    │  只转发 HTTP，不再 301
    ▼
内部路由器  127.0.0.1:5080   （Caddy auto_https off，无站点域名）
    ├─ /healthz  → ok
    ├─ /v2*      → registry-dockerhub
    └─ /         → 纯 Registry（无前端页）
    │
    ▼
7 个官方 registry:2 拉取缓存
```

内部层**永远不碰 80/443、不签证书、不按 Host 跳 HTTPS**。  
上一版 `ERR_TOO_MANY_REDIRECTS` 就是「Nginx HTTPS → 内部 Caddy 再 308 回 HTTPS」。

## 决策表

| 80 | 443 | MODE | 边缘谁签证书 |
| --- | --- | --- | --- |
| 空 / 本站 edge | 空 / 本站 edge | `direct` | 本仓库 `edge` 容器 |
| Nginx | 任意 | `behind-nginx` | certbot webroot，或复用已有 pem |
| 空 | Nginx | `behind-nginx` | 同上 |
| 宿主机 Caddy | 任意 | `behind-caddy` | 那套 Caddy |
| 其它进程 / 别人的容器 | — | `behind-unknown` | 不改，打印片段后失败 |

换一台 80/443 空闲的机器，同一条安装命令会走 `direct`。  
这台被 3x-ui 占着的机器走 `behind-nginx`。

## Nginx 同机额外动作

1. 把其它 conf 里相同的 `server_name` 改成 `主机.disabled-by-docker-mirror`（渡口不再抢走域名）。
2. HTTP 和 HTTPS 都 `proxy_pass` 到 `127.0.0.1:5080`，**HTTP 不 301**。
3. `ssl_certificate` 必须是单个绝对路径；`nginx -t` 失败回滚。
4. 证书日志走 stderr，路径单独落盘，避免再污染配置。

## 客户端

`registry-mirrors` 只认 Docker Hub，填 `https://SITE_ADDRESS`。  
Cloudflare 必须灰云。
