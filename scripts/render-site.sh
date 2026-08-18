#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f "$ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$ROOT/.env"
  set +a
fi

SITE_ADDRESS="${SITE_ADDRESS:-mirror.example.com}"
DOMAIN="${DOMAIN:-example.com}"
MIRROR="https://${SITE_ADDRESS}"

mkdir -p www

cat > www/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Docker 镜像加速站</title>
  <style>
    :root {
      --bg: #0b1220;
      --card: #121a2b;
      --line: #243049;
      --text: #e8eefc;
      --muted: #9aa8c7;
      --accent: #4cc2ff;
      --ok: #3dd68c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(900px 400px at 10% -10%, #1a3a66 0%, transparent 55%),
        radial-gradient(700px 360px at 100% 0%, #163024 0%, transparent 50%),
        var(--bg);
      color: var(--text);
      line-height: 1.6;
    }
    main { max-width: 920px; margin: 0 auto; padding: 48px 20px 80px; }
    h1 { font-size: 34px; margin: 0 0 8px; letter-spacing: -0.03em; }
    .sub { color: var(--muted); margin-bottom: 28px; }
    .grid { display: grid; gap: 16px; }
    .card {
      background: rgba(18, 26, 43, 0.88);
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 20px 22px;
    }
    h2 { margin: 0 0 10px; font-size: 18px; }
    code, pre {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 13px;
    }
    pre {
      background: #0a1020;
      border: 1px solid #1d2942;
      border-radius: 12px;
      padding: 14px 16px;
      overflow: auto;
      color: #d7e4ff;
    }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; }
    .pill {
      display: inline-block;
      background: #16324a;
      color: var(--accent);
      border-radius: 999px;
      padding: 2px 10px;
      font-size: 12px;
      margin-bottom: 12px;
    }
    a { color: var(--accent); }
    .ok { color: var(--ok); }
  </style>
</head>
<body>
  <main>
    <div class="pill">美国节点 · HTTPS 拉取缓存</div>
    <h1>Docker 镜像加速站</h1>
    <p class="sub">国内服务器把 Docker Hub 指到 <code>${MIRROR}</code> 即可。其他仓库改子域名前缀。</p>

    <div class="grid">
      <section class="card">
        <h2>1. Docker Hub（镜像名不用改）</h2>
        <pre>{
  "registry-mirrors": ["${MIRROR}"]
}</pre>
        <p>群晖：Container Manager / Docker → 设置 → Registry，添加上面这个地址后重启套件。</p>
        <p>Linux 一键：</p>
        <pre>curl -fsSL ${MIRROR}/install.sh | sudo MIRROR=${MIRROR} sh
docker pull nginx:alpine</pre>
      </section>

      <section class="card">
        <h2>2. 其他仓库（改前缀）</h2>
        <table>
          <thead>
            <tr><th>原地址</th><th>加速地址</th></tr>
          </thead>
          <tbody>
            <tr><td>docker.io / 官方镜像</td><td>${MIRROR}（registry-mirrors）</td></tr>
            <tr><td>ghcr.io/xxx</td><td>ghcr.${DOMAIN}/xxx</td></tr>
            <tr><td>gcr.io/xxx</td><td>gcr.${DOMAIN}/xxx</td></tr>
            <tr><td>quay.io/xxx</td><td>quay.${DOMAIN}/xxx</td></tr>
            <tr><td>registry.k8s.io/xxx</td><td>k8s.${DOMAIN}/xxx</td></tr>
            <tr><td>nvcr.io/xxx</td><td>nvcr.${DOMAIN}/xxx</td></tr>
            <tr><td>mcr.microsoft.com/xxx</td><td>mcr.${DOMAIN}/xxx</td></tr>
          </tbody>
        </table>
        <pre>docker pull ghcr.${DOMAIN}/actions/runner:latest
docker pull k8s.${DOMAIN}/pause:3.9</pre>
      </section>

      <section class="card">
        <h2>注意</h2>
        <p class="ok">registry-mirrors 只加速 Docker Hub。GitHub / k8s / Quay 必须改前缀。</p>
        <p>私有镜像请继续走原地址登录拉取。</p>
      </section>
    </div>
  </main>
</body>
</html>
EOF

echo "已生成 www/index.html （${MIRROR}）"
