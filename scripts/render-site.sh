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
  <title>Docker 镜像加速 · ${SITE_ADDRESS}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0b1220;
      --bg2: #111827;
      --card: rgba(17, 24, 39, .78);
      --line: rgba(148, 163, 184, .16);
      --text: #f8fafc;
      --muted: #94a3b8;
      --accent: #38bdf8;
      --ok: #34d399;
      --warn: #fbbf24;
      --shadow: 0 24px 80px rgba(2, 6, 23, .45);
      --ease: cubic-bezier(.16, 1, .3, 1);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      min-height: 100dvh;
      font-family: Inter, ui-sans-serif, system-ui, sans-serif;
      color: var(--text);
      background:
        radial-gradient(900px 420px at 8% -10%, rgba(56, 189, 248, .16), transparent 55%),
        radial-gradient(720px 380px at 100% 0%, rgba(52, 211, 153, .10), transparent 50%),
        var(--bg);
      line-height: 1.6;
    }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .wrap { width: min(1080px, calc(100% - 32px)); margin: 0 auto; }
    header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 22px 0 8px; gap: 16px;
    }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; letter-spacing: -.02em; }
    .mark {
      width: 34px; height: 34px; border-radius: 10px;
      background: linear-gradient(135deg, #38bdf8, #34d399);
      box-shadow: 0 0 0 4px rgba(56,189,248,.12);
    }
    .status {
      display: inline-flex; align-items: center; gap: 8px;
      padding: 8px 12px; border-radius: 999px;
      border: 1px solid var(--line); background: rgba(15,23,42,.7);
      color: var(--muted); font-size: 13px;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--warn); }
    .dot.ok { background: var(--ok); box-shadow: 0 0 0 4px rgba(52,211,153,.15); }
    .dot.bad { background: #f87171; }
    hero, .hero { padding: 56px 0 28px; }
    h1 { font-size: clamp(34px, 6vw, 56px); line-height: 1.05; letter-spacing: -.045em; margin: 0 0 14px; }
    .lead { max-width: 640px; color: var(--muted); font-size: 17px; margin: 0 0 28px; }
    .cta { display: flex; flex-wrap: wrap; gap: 10px; }
    button, .btn {
      appearance: none; border: 0; cursor: pointer;
      border-radius: 12px; padding: 12px 16px; font: 600 14px Inter, sans-serif;
      transition: transform .18s var(--ease), background .18s var(--ease), border-color .18s var(--ease);
    }
    button:hover, .btn:hover { transform: translateY(-1px); }
    button:focus-visible, .btn:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
    .btn-primary { background: #e2e8f0; color: #0f172a; }
    .btn-ghost { background: transparent; color: var(--text); border: 1px solid var(--line); }
    .grid { display: grid; gap: 16px; grid-template-columns: 1.15fr .85fr; margin: 18px 0 64px; }
    .card {
      background: var(--card); border: 1px solid var(--line); border-radius: 22px;
      padding: 22px; box-shadow: var(--shadow); backdrop-filter: blur(16px);
    }
    h2 { margin: 0 0 8px; font-size: 18px; letter-spacing: -.02em; }
    p.hint { color: var(--muted); margin: 0 0 14px; font-size: 14px; }
    pre, code { font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace; }
    pre {
      margin: 0; padding: 14px 16px; border-radius: 14px; overflow: auto;
      background: #070b14; border: 1px solid #1e293b; color: #dbeafe; font-size: 13px;
    }
    .pre-wrap { position: relative; }
    .copy {
      position: absolute; top: 10px; right: 10px;
      padding: 6px 10px; font-size: 12px; border-radius: 8px;
      background: #1e293b; color: #e2e8f0; border: 1px solid #334155;
    }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 6px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
    .steps { display: grid; gap: 12px; }
    .step { display: grid; grid-template-columns: 28px 1fr; gap: 10px; color: #cbd5e1; font-size: 14px; }
    .n {
      width: 28px; height: 28px; border-radius: 8px; display: grid; place-items: center;
      background: #172033; color: var(--accent); font-size: 12px; font-weight: 700;
    }
    footer { color: var(--muted); font-size: 13px; padding: 0 0 48px; }
    @media (max-width: 860px) {
      .grid { grid-template-columns: 1fr; }
      header { flex-wrap: wrap; }
    }
    @media (prefers-reduced-motion: reduce) {
      * { transition: none !important; scroll-behavior: auto !important; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <header>
      <div class="brand"><span class="mark" aria-hidden="true"></span> NodeLink Mirror</div>
      <div class="status" id="live"><span class="dot" id="dot"></span><span id="live-text">正在检测站点…</span></div>
    </header>

    <section class="hero">
      <h1>国内机器只访问你的域名。</h1>
      <p class="lead">这是部署在美国节点上的 Docker 拉取缓存。群晖和 Linux 把加速地址填成 <code>${MIRROR}</code>，官方镜像名不用改。</p>
      <div class="cta">
        <button class="btn-primary" type="button" data-copy="${MIRROR}">复制加速地址</button>
        <a class="btn btn-ghost" href="#setup">看怎么接入</a>
      </div>
    </section>

    <div class="grid" id="setup">
      <section class="card">
        <h2>Docker Hub</h2>
        <p class="hint">镜像名不用改。填进 registry-mirrors 即可。</p>
        <div class="pre-wrap">
          <button class="copy" type="button" data-copy='{"registry-mirrors": ["${MIRROR}"]}'>复制</button>
          <pre>{
  "registry-mirrors": ["${MIRROR}"]
}</pre>
        </div>
        <p class="hint" style="margin-top:16px">Linux 一键：</p>
        <div class="pre-wrap">
          <button class="copy" type="button" data-copy="curl -fsSL ${MIRROR}/install.sh | sudo MIRROR=${MIRROR} sh">复制</button>
          <pre>curl -fsSL ${MIRROR}/install.sh | sudo MIRROR=${MIRROR} sh
docker pull nginx:alpine</pre>
        </div>
      </section>

      <section class="card">
        <h2>群晖 / 三步</h2>
        <div class="steps">
          <div class="step"><div class="n">1</div><div>打开 Container Manager 或 Docker → 设置 → Registry</div></div>
          <div class="step"><div class="n">2</div><div>添加 <code>${MIRROR}</code></div></div>
          <div class="step"><div class="n">3</div><div>保存并重启套件，再拉 <code>nginx:alpine</code> 验证</div></div>
        </div>
        <p class="hint" style="margin-top:18px">管理后台不在这个域名上，而在服务器 <code>:8088</code>，避免把改配置入口暴露到公网。</p>
      </section>
    </div>

    <section class="card" style="margin-bottom:20px">
      <h2>其它仓库改前缀</h2>
      <p class="hint">registry-mirrors 只对 Docker Hub 生效。</p>
      <table>
        <thead><tr><th>原来</th><th>改成</th></tr></thead>
        <tbody>
          <tr><td>docker.io / 官方镜像</td><td>${MIRROR}</td></tr>
          <tr><td>ghcr.io/xxx</td><td>ghcr.${DOMAIN}/xxx</td></tr>
          <tr><td>gcr.io/xxx</td><td>gcr.${DOMAIN}/xxx</td></tr>
          <tr><td>quay.io/xxx</td><td>quay.${DOMAIN}/xxx</td></tr>
          <tr><td>registry.k8s.io/xxx</td><td>k8s.${DOMAIN}/xxx</td></tr>
          <tr><td>nvcr.io/xxx</td><td>nvcr.${DOMAIN}/xxx</td></tr>
          <tr><td>mcr.microsoft.com/xxx</td><td>mcr.${DOMAIN}/xxx</td></tr>
        </tbody>
      </table>
      <div class="pre-wrap" style="margin-top:16px">
        <button class="copy" type="button" data-copy="docker pull ghcr.${DOMAIN}/actions/runner:latest">复制</button>
        <pre>docker pull ghcr.${DOMAIN}/actions/runner:latest
docker pull k8s.${DOMAIN}/pause:3.9</pre>
      </div>
    </section>

    <footer>私有镜像继续走原地址登录。这是拉取缓存，不是公共镜像站。</footer>
  </div>
  <script>
    const toast = (el, text) => { const old = el.textContent; el.textContent = text; setTimeout(() => el.textContent = old, 1400); };
    document.querySelectorAll("[data-copy]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(btn.getAttribute("data-copy") || "");
          toast(btn, "已复制");
        } catch {
          toast(btn, "复制失败");
        }
      });
    });
    fetch("/healthz", { cache: "no-store" }).then((r) => {
      const ok = r.ok;
      document.getElementById("dot").className = "dot " + (ok ? "ok" : "bad");
      document.getElementById("live-text").textContent = ok ? "站点在线 · /healthz ok" : "站点异常";
    }).catch(() => {
      document.getElementById("dot").className = "dot bad";
      document.getElementById("live-text").textContent = "无法检测站点";
    });
  </script>
</body>
</html>
EOF

echo "已生成 www/index.html （${MIRROR}）"
