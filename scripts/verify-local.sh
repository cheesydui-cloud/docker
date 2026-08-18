#!/usr/bin/env sh
# 不依赖 Docker 的仓库自检：脚本语法、必要文件、配置渲染
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

ok() { printf '  [OK]  %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS + 1)); }
FAILS=0

echo "== 必要文件 =="
for f in \
  install.sh \
  docker-compose.yml \
  registry/config.yml \
  .env.example \
  README.md \
  scripts/deploy.sh \
  scripts/render-caddyfile.sh \
  scripts/render-site.sh \
  scripts/check-dns.sh \
  scripts/healthcheck.sh \
  scripts/configure-client.sh \
  scripts/print-client-config.sh \
  scripts/start-panel.sh \
  panel/app.py \
  panel/docker-mirror-panel.service \
  www/install.sh \
  examples/daemon.json.https
do
  if [ -f "$f" ]; then
    ok "$f"
  else
    fail "缺少 $f"
  fi
done

echo
echo "== Shell 语法 =="
for f in install.sh scripts/*.sh www/install.sh; do
  if sh -n "$f"; then
    ok "sh -n $f"
  else
    fail "sh -n $f"
  fi
done

echo
echo "== 渲染 Caddy / 首页 =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R . "$TMP/src"
cd "$TMP/src"
cat > .env <<'EOF'
SITE_ADDRESS=mirror.example.test
DOMAIN=example.test
ACME_EMAIL=admin@example.test
HTTP_ONLY=false
EOF
sh scripts/render-caddyfile.sh >/dev/null
sh scripts/render-site.sh >/dev/null

if grep -q 'mirror.example.test' caddy/Caddyfile; then ok "Caddyfile 主站"; else fail "Caddyfile 未包含主站"; fi
if grep -q 'registry-dockerhub:5000' caddy/Caddyfile; then ok "Caddyfile 反代 dockerhub"; else fail "Caddyfile 未反代 dockerhub"; fi
if grep -q 'ghcr.example.test' caddy/Caddyfile; then fail "默认不应生成未解析的 ghcr 站点"; else ok "默认不生成多余子域名"; fi
ENABLE_ALL_SUBDOMAINS=true sh scripts/render-caddyfile.sh >/dev/null
if grep -q 'ghcr.example.test' caddy/Caddyfile && grep -q 'k8s.example.test' caddy/Caddyfile; then
  ok "开启 ENABLE_ALL_SUBDOMAINS 后生成子域名"
else
  fail "ENABLE_ALL_SUBDOMAINS 未生成子域名"
fi
SITE_ADDRESS=mirror.example.test DOMAIN=example.test HTTP_ONLY=false ENABLE_ALL_SUBDOMAINS=false sh scripts/render-caddyfile.sh >/dev/null
if grep -q 'https://mirror.example.test' www/index.html; then ok "首页加速地址"; else fail "首页未写入加速地址"; fi
if grep -q 'ghcr.example.test' www/index.html; then ok "首页 ghcr 前缀"; else fail "首页未写入 ghcr 前缀"; fi

cat > .env <<'EOF'
SITE_ADDRESS=:80
DOMAIN=
HTTP_ONLY=true
EOF
sh scripts/render-caddyfile.sh >/dev/null
grep -q 'auto_https off' caddy/Caddyfile || fail "HTTP 模式未关闭自动 HTTPS"
grep -q ':5001' caddy/Caddyfile || fail "HTTP 模式缺少 5001"
ok "HTTP 模式渲染成功"

echo
echo "== docker-compose 结构 =="
cd "$ROOT"
python3 - <<'PY'
from pathlib import Path
import sys
text = Path("docker-compose.yml").read_text(encoding="utf-8")
need = [
    "registry-dockerhub",
    "registry-ghcr",
    "registry-gcr",
    "registry-quay",
    "registry-k8s",
    "registry-nvcr",
    "registry-mcr",
    "caddy",
    "REGISTRY_PROXY_REMOTEURL",
]
missing = [n for n in need if n not in text]
if "5001:5001" in text:
    missing.append("HTTPS 模式不应默认暴露 5001-5006")
if "HTTP_PORT:-5080" not in text:
    missing.append("Caddy 默认应映射 5080，避免抢 80")
if missing:
    print("MISSING:" + ",".join(missing))
    sys.exit(1)
print("compose-ok")
PY
if [ $? -eq 0 ]; then
  ok "compose 含 7 个缓存仓库且未裸露 5001-5006"
else
  fail "docker-compose.yml 结构不对"
fi

python3 -m py_compile panel/app.py
ok "panel/app.py 语法"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -f docker-compose.yml config >/dev/null; then
    ok "docker compose config"
  else
    fail "docker compose config"
  fi
else
  echo "  [SKIP] 本机无 Docker，跳过 compose config"
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "本地校验失败：${FAILS} 项"
  exit 1
fi
echo "本地校验全部通过。"
