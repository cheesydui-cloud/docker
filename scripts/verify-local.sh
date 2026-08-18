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
  scripts/uninstall.sh \
  scripts/render-github-proxy.sh \
  scripts/apply-github-proxy.sh \
  proxy/tinyproxy.conf.tpl \
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
if grep -q 'respond 204' caddy/Caddyfile && ! grep -q 'docker registry cache' caddy/Caddyfile; then
  ok "加速站根路径空白"
else
  fail "加速站根路径仍有文字"
fi
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
if grep -q '3x-ui' panel/index.html || grep -q '宿主机' panel/index.html; then
  fail "下拉文案仍有多余字"
else
  ok "下拉文案已去掉多余说明"
fi
if grep -q '/api/account' panel/app.py && grep -q '/api/account' panel/index.html && grep -q 'id="new-username"' panel/index.html && grep -q '系统设置' panel/index.html && ! grep -q 'data-page="account"' panel/index.html; then
  ok "账号密码在系统设置里"
else
  fail "账号密码未并入系统设置"
fi
if grep -q 'class="sidebar"' panel/index.html && grep -q 'showPage(' panel/index.html && grep -q '运行概览' panel/index.html; then
  ok "控制台是侧边栏布局"
else
  fail "控制台还不是侧边栏"
fi
if grep -q 'id="app-version"' panel/index.html && grep -q 'load_version' panel/app.py && [ -f VERSION ]; then
  ok "侧栏显示版本号"
else
  fail "缺少版本号"
fi
if grep -q 'panel/.secret' panel/index.html || grep -q '群晖只填加速站主机名' panel/index.html || grep -q '域名、证书和接入状态' panel/index.html; then
  fail "页面仍有圈出的说明文案"
else
  ok "圈出的说明文案已去掉"
fi
if grep -q 'status-rows' panel/index.html && grep -q 'compose_ps_rows' panel/app.py; then
  ok "容器状态用表格"
else
  fail "容器状态还不是表格"
fi
if grep -q 'onsubmit="login()' panel/index.html && grep -q 'toast(' panel/index.html && grep -q 'showResult(text, kind, stay)' panel/index.html; then
  ok "登录可回车，操作不强制跳页"
else
  fail "缺少回车登录或不跳页"
fi
if grep -q '/api/upgrade' panel/app.py && grep -q '/api/uninstall' panel/app.py && grep -q 'runUpgrade' panel/index.html && grep -q 'runUninstall' panel/index.html; then
  ok "系统设置可升级卸载"
else
  fail "系统设置缺少升级卸载"
fi
if grep -q 'systemctl restart docker-mirror-panel' scripts/start-panel.sh && grep -q '重启控制台' scripts/upgrade.sh; then
  ok "升级会强制重启控制台进程"
else
  fail "升级可能仍沿用旧面板进程"
fi
if grep -q 'github-proxy' docker-compose.yml && grep -Fq 'profiles: ["github-proxy"]' docker-compose.yml && grep -q 'GITHUB_PROXY_ENABLED' panel/app.py && grep -q 'id="GITHUB_PROXY_ENABLED"' panel/index.html && grep -q '/api/github-proxy' panel/app.py; then
  ok "GitHub 代理独立开关已贯通"
else
  fail "GitHub 代理未贯通面板 / compose"
fi
if grep -q '3128' docker-compose.yml && ! grep -q 'github-proxy' caddy/Caddyfile; then
  ok "GitHub 代理不走加速站 80/443"
else
  fail "GitHub 代理不该挂到加速站 Caddy"
fi
if grep -q 'apply-github-proxy.sh' scripts/upgrade.sh && grep -q 'apply-github-proxy.sh' scripts/deploy.sh; then
  ok "部署/升级会按开关处理代理"
else
  fail "部署或升级没接代理脚本"
fi
TMP_ALLOW="$(mktemp -d)"
cp -R "$ROOT/." "$TMP_ALLOW/src" 2>/dev/null || true
# 只拷必要文件做渲染检查
mkdir -p "$TMP_ALLOW/src/proxy"
cp "$ROOT/proxy/tinyproxy.conf.tpl" "$TMP_ALLOW/src/proxy/"
cp "$ROOT/scripts/render-github-proxy.sh" "$TMP_ALLOW/src/scripts/" 2>/dev/null || mkdir -p "$TMP_ALLOW/src/scripts"
cp "$ROOT/scripts/render-github-proxy.sh" "$TMP_ALLOW/src/scripts/render-github-proxy.sh"
printf 'GITHUB_PROXY_ALLOW=1.2.3.4,5.6.7.8\n' > "$TMP_ALLOW/src/.env"
if ( cd "$TMP_ALLOW/src" && sh scripts/render-github-proxy.sh >/dev/null ) \
  && grep -q 'Allow 1.2.3.4' "$TMP_ALLOW/src/proxy/tinyproxy.conf" \
  && grep -q 'Allow 5.6.7.8' "$TMP_ALLOW/src/proxy/tinyproxy.conf"; then
  ok "tinyproxy 按允许 IP 生成 Allow"
else
  fail "tinyproxy 配置未写入允许 IP"
fi
rm -rf "$TMP_ALLOW"
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
    "github-proxy",
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
if [ -x scripts/uninstall.sh ] && grep -q 'KEEP_DATA' scripts/uninstall.sh && grep -q 'docker-mirror-panel' scripts/uninstall.sh; then
  ok "uninstall.sh 可执行且不卸 Docker"
else
  fail "uninstall.sh 不完整"
fi
if grep -q '卸载' README.md && grep -q 'scripts/uninstall.sh' README.md && grep -q 'scripts/upgrade.sh' README.md; then
  ok "README 含升级和卸载命令"
else
  fail "README 缺少升级或卸载命令"
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
