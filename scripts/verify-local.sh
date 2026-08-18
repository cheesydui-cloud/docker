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
  scripts/adapt-host.sh \
  scripts/upgrade.sh \
  scripts/render-edge.sh \
  scripts/nginx-disarm-servername.py \
  scripts/cert-status.sh \
  panel/app.py \
  panel/index.html \
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
HTTP_ONLY=true
PANEL_ADDRESS=panel.example.test
EDGE_PREFERENCE=auto
EOF
sh scripts/render-caddyfile.sh >/dev/null
sh scripts/render-edge.sh >/dev/null
sh scripts/render-site.sh >/dev/null

if grep -q 'auto_https off' caddy/Caddyfile; then ok "内部路由关闭 auto_https"; else fail "内部路由未关闭 auto_https"; fi
if grep -q 'mirror.example.test' caddy/Caddyfile; then fail "内部路由不应出现站点域名（会 308）"; else ok "内部路由不含站点域名"; fi
if grep -q 'registry-dockerhub:5000' caddy/Caddyfile; then ok "内部路由反代 dockerhub"; else fail "内部路由未反代 dockerhub"; fi
if grep -q ':5001' caddy/Caddyfile; then ok "内部路由含 5001"; else fail "内部路由缺少 5001"; fi
if grep -q 'mirror.example.test' caddy/Caddyfile.edge; then ok "边缘 Caddy 含主站"; else fail "边缘 Caddy 未含主站"; fi
if grep -q 'reverse_proxy caddy:80' caddy/Caddyfile.edge; then ok "边缘反代内部 HTTP"; else fail "边缘未反代内部 HTTP"; fi
if grep -q 'panel.example.test' caddy/Caddyfile.edge && grep -q 'host.docker.internal:8088' caddy/Caddyfile.edge; then
  ok "边缘含面板域名"
else
  fail "边缘未生成面板域名"
fi
if grep -q 'ghcr.example.test' caddy/Caddyfile.edge; then fail "默认不应生成未解析的 ghcr 站点"; else ok "默认不生成多余子域名"; fi
ENABLE_ALL_SUBDOMAINS=true sh scripts/render-edge.sh >/dev/null
if grep -q 'ghcr.example.test' caddy/Caddyfile.edge && grep -q 'k8s.example.test' caddy/Caddyfile.edge; then
  ok "开启 ENABLE_ALL_SUBDOMAINS 后边缘生成子域名"
else
  fail "ENABLE_ALL_SUBDOMAINS 未生成子域名"
fi
if awk '
  $0 ~ /handle \{/ {in_default=1}
  in_default && $0 ~ /file_server/ {print "default-file-server"; exit 1}
  in_default && $0 ~ /^\}/ {in_default=0}
' caddy/Caddyfile; then
  ok "默认路径不再 file_server"
else
  fail "默认路径还在当网站"
fi
if grep -q 'docker registry cache' caddy/Caddyfile; then ok "加速站根路径无前端"; else fail "加速站根路径仍像网站"; fi
if grep -q 'handle /install.sh' caddy/Caddyfile; then ok "仍提供 /install.sh"; else fail "缺少 /install.sh"; fi
if grep -q '/api/cert' panel/index.html && grep -q '操作结果' panel/index.html; then
  ok "控制台含证书卡片和结果区"
else
  fail "控制台缺少证书或结果区"
fi
if grep -q 'self._html(load_page())' panel/app.py && grep -q '/api/cert' panel/app.py; then
  ok "面板从 index.html 读取并提供 /api/cert"
else
  fail "面板未接线 load_page /api/cert"
fi
if grep -q 'kv cert_ok' scripts/cert-status.sh; then
  ok "cert-status.sh 输出 cert_ok"
else
  fail "cert-status.sh 缺少 cert_ok"
fi
if grep -q 'id="EDGE_PREFERENCE"' panel/index.html && grep -q 'behind-nginx' panel/index.html && grep -q 'behind-caddy' panel/index.html; then
  ok "控制台可选 Nginx / Caddy / 直连"
else
  fail "控制台缺少边缘接入选择"
fi
if grep -q 'EDGE_PREFERENCE' panel/app.py && grep -q 'EDGE_PREFERENCE' scripts/adapt-host.sh; then
  ok "面板选择会写入 EDGE_PREFERENCE"
else
  fail "EDGE_PREFERENCE 未贯通"
fi
if grep -R -n 'nodelink.uk' --include='*.sh' --include='*.py' --include='*.yml' --include='*.html' --include='*.md' --include='*.example' --include='*.conf' --include='*.caddyfile' . | grep -v './.git/' | grep -v './scripts/verify-local.sh'; then
  fail "代码里仍有写死的 nodelink.uk"
else
  ok "业务代码未写死 nodelink.uk"
fi

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
    "edge",
    "REGISTRY_PROXY_REMOTEURL",
]
missing = [n for n in need if n not in text]
if "5001:5001" in text:
    missing.append("HTTPS 模式不应默认暴露 5001-5006")
if "HTTP_PORT:-5080" not in text:
    missing.append("内部 Caddy 默认应映射 5080，避免抢 80")
if 'profiles: ["direct"]' not in text:
    missing.append("edge 必须挂在 direct profile")
if "host.docker.internal:host-gateway" not in text:
    missing.append("edge 需要 host.docker.internal 才能反代面板")
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
python3 -m py_compile scripts/nginx-disarm-servername.py
ok "nginx-disarm-servername.py 语法"

if sh scripts/adapt-host.sh detect | grep -q '^MODE='; then
  ok "adapt-host detect 输出 MODE"
else
  fail "adapt-host detect 无 MODE"
fi
if grep -q 'behind-nginx' scripts/adapt-host.sh && grep -q 'behind-caddy' scripts/adapt-host.sh && grep -q 'certbot certonly' scripts/adapt-host.sh; then
  ok "adapt-host 含 Nginx/Caddy/证书分支"
else
  fail "adapt-host 分支不完整"
fi
if grep -q 'need_cmd git' scripts/upgrade.sh && grep -q 'install_pkg' scripts/upgrade.sh && grep -q '本机还没装过' scripts/upgrade.sh && ! grep -q '需要 git' scripts/upgrade.sh; then
  ok "upgrade.sh 缺 git 会自动安装，没装过会先起控制台"
else
  fail "upgrade.sh 仍会因缺 git 或未安装目录直接退出"
fi
DET_PREF="$(mktemp)"
if EDGE_PREFERENCE=nginx sh scripts/adapt-host.sh detect >"$DET_PREF" && grep -q "MODE='behind-nginx'" "$DET_PREF"; then
  ok "EDGE_PREFERENCE=nginx 强制 behind-nginx"
else
  fail "面板指定 Nginx 未生效"
  sed -n '1,8p' "$DET_PREF" || true
fi
rm -f "$DET_PREF"

# 回归：探测结果里的括号不能把 sh source 弄挂（v1.0.3 线上故障）
STATE_TMP="$(mktemp)"
REASON_SAMPLE='80 已被 Nginx(pid=1234) 占用'
# 复用脚本里的 quote 方式
printf "MODE='%s'\n" "behind-nginx" > "$STATE_TMP"
printf "REASON='%s'\n" "$(printf '%s' "$REASON_SAMPLE" | sed "s/'/'\\\\''/g")" >> "$STATE_TMP"
if ( set -eu; # shellcheck disable=SC1090
     . "$STATE_TMP"
     [ "$MODE" = "behind-nginx" ] && [ "$REASON" = "$REASON_SAMPLE" ]
   ); then
  ok "state.env 含括号时可以 source"
else
  fail "state.env 含括号时 source 失败"
fi
rm -f "$STATE_TMP"

echo
echo "== Nginx 证书路径 / 日志隔离 =="
# detect 的 stdout 只能是 KEY='value'，日志必须在 stderr
DET_OUT="$(mktemp)"
DET_ERR="$(mktemp)"
if sh scripts/adapt-host.sh detect >"$DET_OUT" 2>"$DET_ERR"; then
  if grep -q "^MODE=" "$DET_OUT" && ! grep -qvE '^[A-Z0-9_]+=' "$DET_OUT"; then
    ok "detect stdout 只有 KEY=value"
  else
    fail "detect stdout 混入了非赋值行"
    sed -n '1,20p' "$DET_OUT" || true
  fi
else
  fail "adapt-host detect 退出非 0"
fi
rm -f "$DET_OUT" "$DET_ERR"

SSL_OUT="$(mktemp)"
if sh scripts/adapt-host.sh gen-nginx-ssl docker.example.test \
    /etc/letsencrypt/live/docker.example.test/fullchain.pem \
    /etc/letsencrypt/live/docker.example.test/privkey.pem >"$SSL_OUT"; then
  if awk '
    $1=="ssl_certificate" { if (NF!=2 || $2 !~ /^\/etc\/letsencrypt\/live\/docker\.example\.test\/fullchain\.pem;?$/) { print "bad-cert", NF, $0; exit 1 } }
    $1=="ssl_certificate_key" { if (NF!=2 || $2 !~ /^\/etc\/letsencrypt\/live\/docker\.example\.test\/privkey\.pem;?$/) { print "bad-key", NF, $0; exit 1 } }
  ' "$SSL_OUT"; then
    ok "ssl_certificate 恰好一个绝对路径"
  else
    fail "生成的 ssl_certificate 参数个数不对"
    grep ssl_certificate "$SSL_OUT" || true
  fi
  if grep -E 'return 301|return 308' "$SSL_OUT"; then
    fail "Nginx 站点不应 301/308 到自身"
  else
    ok "Nginx 站点不做二次跳转"
  fi
  if grep -q 'proxy_pass http://127.0.0.1:5080' "$SSL_OUT"; then
    ok "加速站反代内部 5080"
  else
    fail "加速站未反代 5080"
  fi
else
  fail "gen-nginx-ssl 失败"
fi
rm -f "$SSL_OUT"

# 面板站点：同一个生成器，目标应能改成 8088
# 通过内部函数间接验证：nginx_http_only_server 第二参数
if grep -q 'PANEL_BACKEND=' scripts/adapt-host.sh && grep -q 'docker-mirror-panel.conf' scripts/adapt-host.sh; then
  ok "adapt-host 含面板域名接入"
else
  fail "adapt-host 缺少面板域名接入"
fi

DISARM_IN="$(mktemp)"
DISARM_NGINX="$(mktemp)"
cat > "$DISARM_IN" <<'EOF'
server {
    listen 443 ssl;
    server_name docker.example.test d-ui.example.test;
}
EOF
	{
	  printf '# configuration file %s:\n' "$DISARM_IN"
	  cat "$DISARM_IN"
	} > "$DISARM_NGINX"
if python3 scripts/nginx-disarm-servername.py docker.example.test /tmp/docker-mirror.conf "$DISARM_NGINX" >/dev/null; then
  if grep -q 'docker.example.test.disabled-by-docker-mirror' "$DISARM_IN" && grep -q 'd-ui.example.test' "$DISARM_IN"; then
    ok "冲突 server_name 会被改名，其它主机名保留"
  else
    fail "冲突 server_name 改写结果不对"
    cat "$DISARM_IN"
  fi
else
  fail "nginx-disarm-servername.py 失败"
fi
rm -f "$DISARM_IN" "$DISARM_NGINX" "${DISARM_IN}.bak.disabled-by-docker-mirror"

if sh scripts/adapt-host.sh gen-nginx-ssl docker.example.test \
    $'已有证书 /etc/letsencrypt/live/x ，复用\n/etc/letsencrypt/live/x/fullchain.pem' \
    /etc/letsencrypt/live/x/privkey.pem >/dev/null 2>&1; then
  fail "污染后的证书路径本应被拒绝"
else
  ok "污染后的证书路径被拒绝"
fi

if sh scripts/adapt-host.sh gen-nginx-ssl docker.example.test \
    "/tmp/has space/fullchain.pem" \
    /tmp/privkey.pem >/dev/null 2>&1; then
  fail "含空格的证书路径本应被拒绝"
else
  ok "含空格的证书路径被拒绝"
fi

if [ -x scripts/upgrade.sh ]; then
  ok "upgrade.sh 可执行"
else
  fail "upgrade.sh 不可执行"
fi

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
