#!/usr/bin/env python3
"""Docker 镜像加速站控制面板（仅标准库）。"""
from __future__ import annotations

import json
import os
import secrets
import subprocess
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(os.environ.get("MIRROR_ROOT", Path(__file__).resolve().parent.parent)).resolve()
SECRET_FILE = ROOT / "panel" / ".secret"
ENV_FILE = ROOT / ".env"
HOST = os.environ.get("PANEL_HOST", "0.0.0.0")
PORT = int(os.environ.get("PANEL_PORT", "8088"))
JOB_LOCK = threading.Lock()
JOB = {"running": False, "log": "", "ok": None, "started": 0, "finished": 0}

ENV_KEYS = [
    "SITE_ADDRESS",
    "DOMAIN",
    "ACME_EMAIL",
    "HTTP_ONLY",
    "DOCKERHUB_USERNAME",
    "DOCKERHUB_PASSWORD",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "HTTP_PORT",
    "HTTPS_PORT",
    "HTTP_BIND",
    "HTTPS_BIND",
]


def ensure_secret() -> str:
    SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
    if SECRET_FILE.exists():
        token = SECRET_FILE.read_text(encoding="utf-8").strip()
        if token:
            return token
    token = secrets.token_urlsafe(18)
    SECRET_FILE.write_text(token + "\n", encoding="utf-8")
    try:
        os.chmod(SECRET_FILE, 0o600)
    except OSError:
        pass
    return token


TOKEN = ensure_secret()


def load_env() -> dict:
    data = {
        "SITE_ADDRESS": "mirror.example.com",
        "DOMAIN": "example.com",
        "ACME_EMAIL": "admin@example.com",
        "HTTP_ONLY": "false",
        "DOCKERHUB_USERNAME": "",
        "DOCKERHUB_PASSWORD": "",
        "HTTP_PROXY": "",
        "HTTPS_PROXY": "",
        "NO_PROXY": "localhost,127.0.0.1,caddy,registry-dockerhub,registry-ghcr,registry-gcr,registry-quay,registry-k8s,registry-nvcr,registry-mcr",
        "HTTP_PORT": "5080",
        "HTTPS_PORT": "5443",
        "HTTP_BIND": "127.0.0.1",
        "HTTPS_BIND": "127.0.0.1",
    }
    if not ENV_FILE.exists():
        return data
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value
    return data


def write_env(values: dict) -> None:
    current = load_env()
    for key in ENV_KEYS:
        if key in values and values[key] is not None:
            current[key] = str(values[key]).strip()
    domain = current.get("DOMAIN", "").strip().lower()
    domain = domain.replace("https://", "").replace("http://", "").strip("/")
    if domain.startswith("mirror."):
        domain = domain[7:]
    current["DOMAIN"] = domain
    site = current.get("SITE_ADDRESS", "").strip().lower()
    site = site.replace("https://", "").replace("http://", "").strip("/")
    if not site or site in {"mirror.example.com", "example.com"}:
        site = f"mirror.{domain}" if domain else site
    current["SITE_ADDRESS"] = site
    if current.get("HTTP_ONLY", "false").lower() in {"1", "true", "yes", "on"}:
        current["HTTP_ONLY"] = "true"
    else:
        current["HTTP_ONLY"] = "false"
    lines = [
        f"SITE_ADDRESS={current['SITE_ADDRESS']}",
        f"DOMAIN={current['DOMAIN']}",
        f"ACME_EMAIL={current['ACME_EMAIL']}",
        f"HTTP_ONLY={current['HTTP_ONLY']}",
        f"DOCKERHUB_USERNAME={current.get('DOCKERHUB_USERNAME', '')}",
        f"DOCKERHUB_PASSWORD={current.get('DOCKERHUB_PASSWORD', '')}",
        f"HTTP_PROXY={current.get('HTTP_PROXY', '')}",
        f"HTTPS_PROXY={current.get('HTTPS_PROXY', '')}",
        f"NO_PROXY={current.get('NO_PROXY', '')}",
        f"HTTP_PORT={current.get('HTTP_PORT', '5080')}",
        f"HTTPS_PORT={current.get('HTTPS_PORT', '5443')}",
        f"HTTP_BIND={current.get('HTTP_BIND', '127.0.0.1')}",
        f"HTTPS_BIND={current.get('HTTPS_BIND', '127.0.0.1')}",
        "",
    ]
    ENV_FILE.write_text("\n".join(lines), encoding="utf-8")


def public_config() -> dict:
    data = load_env()
    pwd = data.get("DOCKERHUB_PASSWORD") or ""
    data["DOCKERHUB_PASSWORD_SET"] = bool(pwd)
    data["DOCKERHUB_PASSWORD"] = "********" if pwd else ""
    data["panel_port"] = PORT
    return data


def run_cmd(args: list[str], timeout: int = 180) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, out + "\n命令超时"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def append_job(text: str) -> None:
    JOB["log"] += text
    if not text.endswith("\n"):
        JOB["log"] += "\n"


def deploy_job(payload: dict) -> None:
    JOB["running"] = True
    JOB["ok"] = None
    JOB["log"] = ""
    JOB["started"] = int(time.time())
    JOB["finished"] = 0
    try:
        write_env(payload)
        append_job("已写入域名 / 邮箱 / Docker Hub 配置")
        skip_dns = bool(payload.get("skip_dns"))
        if not skip_dns:
            append_job("== 检查 DNS ==")
            code, out = run_cmd(["sh", "scripts/check-dns.sh"], timeout=60)
            append_job(out)
            if code != 0:
                raise RuntimeError("DNS 未就绪。请先把加速站主机名解析到这台美国服务器，或勾选跳过 DNS。")
        append_job("== 探测 80/443 占用并自动选择接入方式 ==")
        code, out = run_cmd(["sh", "scripts/adapt-host.sh", "configure"], timeout=60)
        append_job(out)
        if code != 0:
            raise RuntimeError("主机探测失败")
        append_job("== 生成站点与内部 Caddy 配置 ==")
        for script in ("scripts/render-site.sh", "scripts/render-caddyfile.sh"):
            code, out = run_cmd(["sh", script], timeout=30)
            append_job(out)
            if code != 0:
                raise RuntimeError(f"{script} 失败")
        append_job("== 启动 / 更新容器 ==")
        code, out = run_cmd(["docker", "compose", "pull"], timeout=300)
        append_job(out)
        code, out = run_cmd(["docker", "compose", "up", "-d"], timeout=300)
        append_job(out)
        if code != 0:
            raise RuntimeError("docker compose up 失败")
        time.sleep(3)
        append_job("== 接入现有 Nginx/Caddy 并处理证书 ==")
        code, out = run_cmd(["sh", "scripts/adapt-host.sh", "integrate"], timeout=240)
        append_job(out)
        if code != 0:
            raise RuntimeError("自动接入失败（后端多半已起来，看上面探测结果）")
        append_job("== 健康检查 ==")
        code, out = run_cmd(["sh", "scripts/healthcheck.sh"], timeout=120)
        append_job(out)
        append_job("== 国内客户端配置 ==")
        _, out = run_cmd(["sh", "scripts/print-client-config.sh"], timeout=20)
        append_job(out)
        env = load_env()
        site = env.get("SITE_ADDRESS", "docker.example.com")
        JOB["ok"] = True
        append_job(f"部署完成。浏览器打开 https://{site}/ 应是镜像站说明页。")
    except Exception as exc:  # noqa: BLE001
        JOB["ok"] = False
        append_job(f"失败：{exc}")
    finally:
        JOB["running"] = False
        JOB["finished"] = int(time.time())


def start_job(payload: dict) -> bool:
    with JOB_LOCK:
        if JOB["running"]:
            return False
        JOB["running"] = True
    threading.Thread(target=deploy_job, args=(payload,), daemon=True).start()
    return True


def compose_ps() -> str:
    code, out = run_cmd(["docker", "compose", "ps"], timeout=30)
    return out if out.strip() else ("(无法读取容器状态)" if code else "(暂无容器)")


def compose_logs(service: str = "caddy") -> str:
    service = service if service in {
        "caddy",
        "registry-dockerhub",
        "registry-ghcr",
        "registry-gcr",
        "registry-quay",
        "registry-k8s",
        "registry-nvcr",
        "registry-mcr",
    } else "caddy"
    _, out = run_cmd(["docker", "compose", "logs", "--tail=120", service], timeout=30)
    return out


PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>镜像加速站控制台</title>
  <style>
    :root { --bg:#0b1220; --card:#121a2b; --line:#243049; --text:#e8eefc; --muted:#9aa8c7; --accent:#4cc2ff; --ok:#3dd68c; --bad:#ff6b7a; }
    * { box-sizing:border-box; }
    body { margin:0; font-family:ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:radial-gradient(900px 400px at 10% -10%,#1a3a66 0%,transparent 55%),var(--bg); color:var(--text); }
    main { max-width:980px; margin:0 auto; padding:36px 18px 80px; }
    h1 { margin:0 0 6px; letter-spacing:-.03em; }
    .sub { color:var(--muted); margin-bottom:22px; }
    .card { background:rgba(18,26,43,.9); border:1px solid var(--line); border-radius:16px; padding:18px 20px; margin-bottom:14px; }
    label { display:block; font-size:13px; color:var(--muted); margin:10px 0 6px; }
    input, select { width:100%; padding:10px 12px; border-radius:10px; border:1px solid #2a3a58; background:#0a1020; color:var(--text); }
    .row { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    .btns { display:flex; flex-wrap:wrap; gap:8px; margin-top:14px; }
    button { border:0; border-radius:10px; padding:10px 14px; cursor:pointer; font-weight:600; }
    .primary { background:#2b7cff; color:#fff; }
    .ghost { background:#1a2438; color:var(--text); }
    .danger { background:#5a2030; color:#ffd6dc; }
    pre { background:#0a1020; border:1px solid #1d2942; border-radius:12px; padding:12px; overflow:auto; min-height:120px; white-space:pre-wrap; font-size:12px; }
    .ok { color:var(--ok); } .bad { color:var(--bad); }
    .pill { display:inline-block; background:#16324a; color:var(--accent); border-radius:999px; padding:2px 10px; font-size:12px; margin-bottom:10px; }
    .check { display:flex; align-items:center; gap:8px; margin-top:12px; color:var(--muted); }
    .check input { width:auto; }
    @media (max-width:800px){ .row{grid-template-columns:1fr;} }
  </style>
</head>
<body>
<main>
  <div class="pill">网页部署 · 不用记命令</div>
  <h1>镜像加速站控制台</h1>
  <p class="sub">在这里填写域名、邮箱和 Docker Hub 账号，点「保存并部署」。美国服务器会自动签证书并启动缓存。</p>

  <section class="card" id="login-card">
    <h2>登录</h2>
    <p class="sub">安装脚本结束时打印的面板密码，也在服务器文件 <code>/opt/docker-mirror/panel/.secret</code></p>
    <label>面板密码</label>
    <input id="token" type="password" autocomplete="current-password">
    <div class="btns"><button class="primary" onclick="login()">进入面板</button></div>
    <p id="login-msg" class="bad"></p>
  </section>

  <div id="app" style="display:none">
    <section class="card">
      <h2>部署参数</h2>
      <div class="row">
        <div>
          <label>主域名（example.com，不要带 https）</label>
          <input id="DOMAIN" placeholder="example.com">
        </div>
        <div>
          <label>加速站主机名</label>
          <input id="SITE_ADDRESS" placeholder="mirror.example.com">
        </div>
      </div>
      <div class="row">
        <div>
          <label>证书邮箱</label>
          <input id="ACME_EMAIL" placeholder="admin@example.com">
        </div>
        <div>
          <label>模式</label>
          <select id="HTTP_ONLY">
            <option value="false">HTTPS + 域名（推荐，美国服务器）</option>
            <option value="true">仅 HTTP / 内网 IP</option>
          </select>
        </div>
      </div>
      <div class="row">
        <div>
          <label>Docker Hub 用户名（建议填）</label>
          <input id="DOCKERHUB_USERNAME">
        </div>
        <div>
          <label>Docker Hub Token</label>
          <input id="DOCKERHUB_PASSWORD" type="password" placeholder="已保存则留空不改">
        </div>
      </div>
      <div class="row">
        <div>
          <label>HTTP 代理（一般不用）</label>
          <input id="HTTP_PROXY" placeholder="http://127.0.0.1:7890">
        </div>
        <div>
          <label>HTTPS 代理</label>
          <input id="HTTPS_PROXY">
        </div>
      </div>
      <label class="check"><input id="skip_dns" type="checkbox"> 跳过 DNS 检查（解析未生效时临时用，证书仍可能失败）</label>
      <div class="btns">
        <button class="primary" id="btn-deploy" onclick="deploy()">保存并部署</button>
        <button class="ghost" onclick="saveOnly()">只保存</button>
        <button class="ghost" onclick="checkDns()">检查 DNS</button>
        <button class="ghost" onclick="health()">健康检查</button>
        <button class="ghost" onclick="clientCfg()">国内怎么用</button>
        <button class="ghost" onclick="refreshStatus()">刷新状态</button>
        <button class="danger" onclick="restart()">重启服务</button>
      </div>
      <p id="flash" class="sub" style="margin:12px 0 0">点「保存并部署」后，进度会出现在这里和下面的任务日志。</p>
    </section>

    <section class="card">
      <h2>容器状态</h2>
      <pre id="status">(尚未加载)</pre>
    </section>
    <section class="card">
      <h2>任务日志</h2>
      <pre id="job">(空)</pre>
    </section>
    <section class="card">
      <h2>Caddy 日志</h2>
      <div class="btns">
        <button class="ghost" onclick="logs('caddy')">caddy</button>
        <button class="ghost" onclick="logs('registry-dockerhub')">dockerhub</button>
      </div>
      <pre id="logs">(空)</pre>
    </section>
  </div>
</main>
<script>
let TOKEN = localStorage.getItem("mirror_panel_token") || "";
const $ = (id) => document.getElementById(id);

function setJob(text) {
  const el = $("job");
  if (el) el.textContent = text || "(空)";
  const flash = $("flash");
  if (flash) {
    const first = (text || "").split("\n").filter(Boolean)[0] || "";
    flash.textContent = first || "已更新任务日志，请往下看。";
    flash.className = first.indexOf("失败") >= 0 || first.indexOf("错误") >= 0 ? "bad" : "ok";
  }
}

async function api(path, opt={}) {
  const headers = Object.assign({"Authorization": "Bearer " + TOKEN}, opt.headers || {});
  let res;
  try {
    res = await fetch(path, Object.assign({}, opt, {headers}));
  } catch (e) {
    throw new Error("请求没发出去：" + e.message);
  }
  if (res.status === 401) throw new Error("密码错误或未登录，请刷新页面重新登录");
  const text = await res.text();
  try { return JSON.parse(text); } catch { return {raw: text, status: res.status}; }
}

function login() {
  TOKEN = $("token").value.trim();
  localStorage.setItem("mirror_panel_token", TOKEN);
  boot();
}

async function boot() {
  try {
    const cfg = await api("/api/config");
    $("login-card").style.display = "none";
    $("app").style.display = "block";
    for (const k of ["DOMAIN","SITE_ADDRESS","ACME_EMAIL","HTTP_ONLY","DOCKERHUB_USERNAME","HTTP_PROXY","HTTPS_PROXY"]) {
      if (cfg[k] !== undefined) $(k).value = cfg[k];
    }
    $("DOCKERHUB_PASSWORD").placeholder = cfg.DOCKERHUB_PASSWORD_SET ? "已保存，留空不改" : "建议填写 Access Token";
    refreshStatus();
    pollJob();
  } catch (e) {
    $("login-msg").textContent = e.message;
    $("login-card").style.display = "block";
    $("app").style.display = "none";
  }
}

function formPayload() {
  const data = {
    DOMAIN: $("DOMAIN").value.trim(),
    SITE_ADDRESS: $("SITE_ADDRESS").value.trim(),
    ACME_EMAIL: $("ACME_EMAIL").value.trim(),
    HTTP_ONLY: $("HTTP_ONLY").value,
    DOCKERHUB_USERNAME: $("DOCKERHUB_USERNAME").value.trim(),
    HTTP_PROXY: $("HTTP_PROXY").value.trim(),
    HTTPS_PROXY: $("HTTPS_PROXY").value.trim(),
    skip_dns: $("skip_dns").checked,
  };
  const pwd = $("DOCKERHUB_PASSWORD").value.trim();
  if (pwd) data.DOCKERHUB_PASSWORD = pwd;
  if (data.DOMAIN && !data.SITE_ADDRESS) data.SITE_ADDRESS = "mirror." + data.DOMAIN;
  return data;
}

async function saveOnly() {
  try {
    const r = await api("/api/config", {method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(formPayload())});
    setJob(r.ok ? "已保存配置，还没有部署。" : (r.error || "保存失败"));
  } catch (e) {
    setJob("保存失败：" + e.message);
  }
}

async function deploy() {
  const btn = $("btn-deploy");
  if (btn) btn.disabled = true;
  setJob("正在提交部署任务，请稍候...");
  try {
    const r = await api("/api/deploy", {method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(formPayload())});
    if (r.error) { setJob("部署没有开始：" + r.error); return; }
    setJob("任务已提交，正在拉取镜像并申请证书...");
    pollJob();
  } catch (e) {
    setJob("部署失败：" + e.message);
  } finally {
    if (btn) btn.disabled = false;
  }
}

async function pollJob() {
  try {
    const r = await api("/api/job");
    setJob(r.log || "任务已提交，等待日志...");
    if (r.running) setTimeout(pollJob, 1500);
    else refreshStatus();
  } catch (e) {
    setJob("读取任务日志失败：" + e.message);
  }
}

async function checkDns() {
  try {
    await saveOnly();
    setJob("正在检查 DNS...");
    const r = await api("/api/dns");
    setJob(r.output || r.error || "DNS 检查无输出");
  } catch (e) {
    setJob("DNS 检查失败：" + e.message);
  }
}
async function health() {
  try {
    setJob("正在做健康检查...");
    const r = await api("/api/health");
    setJob(r.output || r.error || "健康检查无输出");
  } catch (e) {
    setJob("健康检查失败：" + e.message);
  }
}
async function clientCfg() {
  try {
    const r = await api("/api/client");
    setJob(r.output || r.error || "无输出");
  } catch (e) {
    setJob("读取客户端配置失败：" + e.message);
  }
}
async function refreshStatus() {
  try {
    const r = await api("/api/status");
    $("status").textContent = r.output || r.error || "(空)";
  } catch (e) {
    $("status").textContent = "读取状态失败：" + e.message;
  }
}
async function logs(svc) {
  try {
    const r = await api("/api/logs?service=" + encodeURIComponent(svc || "caddy"));
    $("logs").textContent = r.output || r.error;
  } catch (e) {
    $("logs").textContent = "读日志失败：" + e.message;
  }
}
async function restart() {
  if (!confirm("确定重启加速站容器？")) return;
  try {
    const r = await api("/api/restart", {method:"POST"});
    setJob(r.output || r.error || "已发送重启");
    refreshStatus();
  } catch (e) {
    setJob("重启失败：" + e.message);
  }
}

const domainEl = $("DOMAIN");
if (domainEl) {
  domainEl.addEventListener("blur", () => {
    const d = $("DOMAIN").value.trim().replace(/^https?:\/\//,"").replace(/\/$/,"");
    if (d && !$("SITE_ADDRESS").value.trim()) $("SITE_ADDRESS").value = "mirror." + d.replace(/^mirror\./,"");
  });
}

if (TOKEN) boot();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "MirrorPanel/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print("%s - %s" % (self.address_string(), fmt % args))

    def _authed(self) -> bool:
        header = self.headers.get("Authorization", "")
        token = ""
        if header.startswith("Bearer "):
            token = header[7:].strip()
        if not token:
            raw = self.headers.get("Cookie", "")
            if raw:
                jar = cookies.SimpleCookie()
                jar.load(raw)
                if "token" in jar:
                    token = jar["token"].value
        if not token:
            return False
        try:
            return secrets.compare_digest(token, TOKEN)
        except Exception:
            return False

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _html(self, body: str) -> None:
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path)
        if path.path == "/":
            self._html(PAGE)
            return
        if path.path == "/healthz":
            self._json(200, {"ok": True})
            return
        if not self._authed():
            self._json(401, {"error": "未登录"})
            return
        if path.path == "/api/config":
            self._json(200, public_config())
        elif path.path == "/api/status":
            self._json(200, {"output": compose_ps()})
        elif path.path == "/api/job":
            self._json(200, JOB)
        elif path.path == "/api/dns":
            code, out = run_cmd(["sh", "scripts/check-dns.sh"], timeout=60)
            self._json(200 if code == 0 else 400, {"ok": code == 0, "output": out})
        elif path.path == "/api/health":
            code, out = run_cmd(["sh", "scripts/healthcheck.sh"], timeout=120)
            self._json(200 if code == 0 else 400, {"ok": code == 0, "output": out})
        elif path.path == "/api/client":
            _, out = run_cmd(["sh", "scripts/print-client-config.sh"], timeout=20)
            self._json(200, {"output": out})
        elif path.path == "/api/logs":
            qs = parse_qs(path.query)
            service = (qs.get("service") or ["caddy"])[0]
            self._json(200, {"output": compose_logs(service)})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if not self._authed():
            self._json(401, {"error": "未登录"})
            return
        if path == "/api/config":
            write_env(self._read_json())
            self._json(200, {"ok": True})
        elif path == "/api/deploy":
            if not start_job(self._read_json()):
                self._json(409, {"error": "已有部署任务在跑，请稍候"})
                return
            self._json(200, {"ok": True, "message": "已开始部署"})
        elif path == "/api/restart":
            _, out = run_cmd(["docker", "compose", "up", "-d"], timeout=180)
            self._json(200, {"output": out})
        elif path == "/api/stop":
            _, out = run_cmd(["docker", "compose", "down"], timeout=120)
            self._json(200, {"output": out})
        else:
            self._json(404, {"error": "not found"})


def main() -> None:
    print(f"面板目录: {ROOT}")
    print(f"打开: http://<美国服务器IP>:{PORT}/")
    print(f"面板密码: {TOKEN}")
    print("建议安全组只对自己 IP 放行该端口。")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
