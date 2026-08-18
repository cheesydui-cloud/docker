#!/usr/bin/env python3
"""Docker 镜像加速站控制面板（仅标准库）。"""
from __future__ import annotations

import hmac
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
USER_FILE = ROOT / "panel" / ".user"
ENV_FILE = ROOT / ".env"
PAGE_FILE = ROOT / "panel" / "index.html"
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
    "COMPOSE_PROFILES",
    "EDGE_MODE",
    "PANEL_ADDRESS",
    "PANEL_PORT",
    "EDGE_PREFERENCE",
]


def _chmod_private(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def same_text(left: str, right: str) -> bool:
    a = (left or "").encode("utf-8")
    b = (right or "").encode("utf-8")
    if len(a) != len(b):
        hmac.compare_digest(a, a)
        return False
    return hmac.compare_digest(a, b)


def ensure_secret() -> str:
    SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
    if SECRET_FILE.exists():
        token = SECRET_FILE.read_text(encoding="utf-8").strip()
        if token:
            return token
    token = secrets.token_urlsafe(18)
    SECRET_FILE.write_text(token + "\n", encoding="utf-8")
    _chmod_private(SECRET_FILE)
    return token


def load_password() -> str:
    return ensure_secret()


def load_username() -> str:
    USER_FILE.parent.mkdir(parents=True, exist_ok=True)
    if USER_FILE.exists():
        name = USER_FILE.read_text(encoding="utf-8").strip()
        if name:
            return name
    USER_FILE.write_text("admin\n", encoding="utf-8")
    _chmod_private(USER_FILE)
    return "admin"


def write_account(username: str, password: str) -> None:
    username = (username or "").strip()
    password = (password or "").strip()
    if not username or not password:
        raise ValueError("账号和密码都不能为空")
    if any(ch.isspace() for ch in username):
        raise ValueError("账号不能包含空格")
    if len(username) > 64:
        raise ValueError("账号太长")
    if len(password) < 6:
        raise ValueError("密码至少 6 位")
    USER_FILE.write_text(username + "\n", encoding="utf-8")
    SECRET_FILE.write_text(password + "\n", encoding="utf-8")
    _chmod_private(USER_FILE)
    _chmod_private(SECRET_FILE)


load_username()
ensure_secret()


def load_env() -> dict:
    data = {
        "SITE_ADDRESS": "",
        "DOMAIN": "",
        "ACME_EMAIL": "",
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
        "COMPOSE_PROFILES": "",
        "EDGE_MODE": "",
        "PANEL_ADDRESS": "",
        "PANEL_PORT": str(PORT),
        "EDGE_PREFERENCE": "auto",
    }
    if not ENV_FILE.exists():
        return data
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        data[key.strip()] = value
    return data


def write_env(values: dict) -> None:
    current = load_env()
    for key in ENV_KEYS:
        if key in values and values[key] is not None:
            current[key] = str(values[key]).strip()
    def clean_host(value: str) -> str:
        host = (value or "").strip().lower()
        host = host.replace("https://", "").replace("http://", "").split("/")[0]
        return host

    current["DOMAIN"] = clean_host(current.get("DOMAIN", ""))
    current["SITE_ADDRESS"] = clean_host(current.get("SITE_ADDRESS", ""))
    current["PANEL_ADDRESS"] = clean_host(current.get("PANEL_ADDRESS", ""))
    pref = (current.get("EDGE_PREFERENCE") or "auto").strip().lower()
    aliases = {
        "nginx": "behind-nginx",
        "behind-nginx": "behind-nginx",
        "caddy": "behind-caddy",
        "behind-caddy": "behind-caddy",
        "direct": "direct",
        "edge": "direct",
        "auto": "auto",
    }
    current["EDGE_PREFERENCE"] = aliases.get(pref, "auto")
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
        f"COMPOSE_PROFILES={current.get('COMPOSE_PROFILES', '')}",
        f"EDGE_MODE={current.get('EDGE_MODE', '')}",
        f"EDGE_PREFERENCE={current.get('EDGE_PREFERENCE', 'auto')}",
        f"PANEL_ADDRESS={current.get('PANEL_ADDRESS', '')}",
        f"PANEL_PORT={current.get('PANEL_PORT', str(PORT))}",
        "",
    ]
    ENV_FILE.write_text("\n".join(lines), encoding="utf-8")


def load_version() -> str:
    path = ROOT / "VERSION"
    if path.is_file():
        ver = path.read_text(encoding="utf-8").strip()
        if ver:
            return ver if ver.startswith("v") else "v" + ver
    return "v0"


def public_config() -> dict:
    data = load_env()
    pwd = data.get("DOCKERHUB_PASSWORD") or ""
    data["DOCKERHUB_PASSWORD_SET"] = bool(pwd)
    data["DOCKERHUB_PASSWORD"] = "********" if pwd else ""
    data["panel_port"] = PORT
    data["EDGE_PREFERENCE"] = data.get("EDGE_PREFERENCE") or "auto"
    data["PANEL_USERNAME"] = load_username()
    data["VERSION"] = load_version()
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
        append_job("== 生成站点 / 内部路由 / 边缘证书配置 ==")
        for script in ("scripts/render-site.sh", "scripts/render-caddyfile.sh", "scripts/render-edge.sh"):
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
        site = env.get("SITE_ADDRESS") or ""
        JOB["ok"] = True
        if site:
            append_job(f"部署完成。群晖 / registry-mirrors 填 https://{site}")
        else:
            append_job("部署完成。请在面板填写加速站主机名后再部署一次。")
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
        "edge",
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


def load_page() -> str:
    if PAGE_FILE.is_file():
        return PAGE_FILE.read_text(encoding="utf-8")
    return "<!DOCTYPE html><title>missing panel/index.html</title>"


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
        return same_text(token, load_password())

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
            self._html(load_page())
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
        elif path.path == "/api/cert":
            code, out = run_cmd(["sh", "scripts/cert-status.sh"], timeout=40)
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
        if path == "/api/login":
            body = self._read_json()
            user = str(body.get("username") or "").strip()
            password = str(body.get("password") or "").strip()
            if same_text(user, load_username()) and same_text(password, load_password()):
                self._json(200, {"ok": True, "token": password, "username": user})
            else:
                self._json(401, {"error": "账号或密码错误"})
            return
        if not self._authed():
            self._json(401, {"error": "未登录"})
            return
        if path == "/api/config":
            write_env(self._read_json())
            self._json(200, {"ok": True})
        elif path == "/api/account":
            body = self._read_json()
            current = str(body.get("current_password") or "").strip()
            if not same_text(current, load_password()):
                self._json(400, {"error": "当前密码不对"})
                return
            username = str(body.get("username") or load_username()).strip()
            password = str(body.get("password") or "").strip()
            if not password:
                self._json(400, {"error": "新密码不能为空"})
                return
            try:
                write_account(username, password)
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200, {"ok": True, "username": username, "token": password})
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
    print(f"面板账号: {load_username()}")
    print(f"面板密码: {load_password()}")
    print("建议安全组只对自己 IP 放行该端口。")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
