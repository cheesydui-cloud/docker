#!/usr/bin/env sh
# 自动适配宿主机 80/443：
#   空闲        → 镜像站自己占 80/443，Caddy 签证书
#   Nginx 占用  → 只听 127.0.0.1:5080，写 Nginx 站点，certbot 签证书
#   宿主机 Caddy → 只听 127.0.0.1:5080，写入现有 Caddyfile 并 reload
#   其他占用    → 仍听 5080，尽量识别进程，给出明确失败原因
#
# 日志一律 stderr。stdout 只给 detect 的 KEY='value'，避免证书路径被污染。
#
# 用法：
#   sh scripts/adapt-host.sh detect
#   sh scripts/adapt-host.sh configure
#   sh scripts/adapt-host.sh integrate
#   sh scripts/adapt-host.sh all
#   sh scripts/adapt-host.sh gen-nginx-ssl <site> <fullchain> <privkey>
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

PHASE="${1:-all}"
STATE_DIR="$ROOT/data/adapt"
STATE_FILE="$STATE_DIR/state.env"
CERT_LIVE_FILE="$STATE_DIR/cert.live"
MARKER_BEGIN="# BEGIN docker-mirror"
MARKER_END="# END docker-mirror"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/docker-mirror-acme}"
BACKEND_PORT="${BACKEND_PORT:-5080}"

mkdir -p "$STATE_DIR"

# 永远写 stderr，调用方用命令替换捕获时不会吃到日志
log() { printf '%s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

load_dotenv() {
  if [ -f "$ROOT/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$ROOT/.env"
    set +a
  fi
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"
}

emit() {
  printf '%s=%s\n' "$1" "$(shell_quote "$2")"
}

write_kv() {
  file="$1"
  key="$2"
  value="$3"
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  else
    : > "$tmp"
  fi
  emit "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

set_env() {
  write_kv "$ROOT/.env" "$1" "$2"
}

# 证书 / 私钥路径必须是单个 Unix 路径，不能含空白或换行
assert_pem_path() {
  label="$1"
  path="$2"
  if [ -z "$path" ]; then
    fail "${label} 为空"
  fi
  case "$path" in
    *$'\n'*|*$'\r'*|*' '*|*$'\t'*)
      fail "${label} 含空白/换行，拒绝写入 Nginx：$(printf '%s' "$path" | tr '\n\r\t' '___')"
      ;;
  esac
  case "$path" in
    /*) ;;
    *) fail "${label} 必须是绝对路径：$path" ;;
  esac
  case "$path" in
    *[!A-Za-z0-9/._+-]*)
      fail "${label} 含非法字符：$path"
      ;;
  esac
}

assert_pem_file() {
  label="$1"
  path="$2"
  assert_pem_path "$label" "$path"
  [ -f "$path" ] || fail "${label} 不存在：$path"
  [ -s "$path" ] || fail "${label} 是空文件：$path"
}

sanitize_live_dir() {
  raw="$(printf '%s' "${1:-}" | tr -d '\r')"
  # 只取最后一行里看起来像 live 目录的路径
  live="$(printf '%s\n' "$raw" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\/etc\/letsencrypt\/live\/[A-Za-z0-9._-]+\/?$/) {
          gsub(/\/$/, "", $i)
          print $i
        }
      }
    }
  ' | tail -n1)"
  if [ -z "$live" ]; then
    live="$(printf '%s\n' "$raw" | awk '/^\/etc\/letsencrypt\/live\/[A-Za-z0-9._-]+$/ {print; found=1} END{if(!found) exit 1}' | tail -n1)" || live=""
  fi
  [ -n "$live" ] || fail "无法从输出中解析证书目录"
  assert_pem_path "证书目录" "$live"
  printf '%s' "$live"
}

owner_of_port() {
  port="$1"
  line=""
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" || $4 ~ ":"p"$" {print; exit}')"
    if [ -z "$line" ]; then
      line="$(ss -lntp 2>/dev/null | grep -E "[:.]${port} " | head -n1 || true)"
    fi
  fi
  pid="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n1)"
  proc=""
  docker_name=""
  if [ -n "$pid" ] && [ -r "/proc/$pid/comm" ]; then
    proc="$(tr -d '\n' < "/proc/$pid/comm")"
  fi
  if [ -z "$proc" ] && [ -n "$line" ]; then
    proc="$(printf '%s' "$line" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')"
  fi
  if [ "$proc" = "docker-proxy" ] || [ "$proc" = "dockerd" ]; then
    if command -v docker >/dev/null 2>&1; then
      docker_name="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v p=":${port}->" '$0 ~ p {print $1; exit}')"
      if [ -z "$docker_name" ]; then
        docker_name="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v p=":${port}->" 'index($0, p) {print $1; exit}')"
      fi
    fi
  fi
  if [ -z "$line" ]; then
    printf 'none||'
    return 0
  fi
  printf '%s|%s|%s' "${proc:-unknown}" "${pid:-}" "${docker_name:-}"
}

classify_owner() {
  proc="$1"
  dname="$2"
  case "$dname" in
    *docker-mirror-caddy*|*caddy*)
      printf 'self-caddy'
      return 0
      ;;
  esac
  case "$proc" in
    ""|none) printf 'free' ;;
    nginx|nginx:*) printf 'nginx' ;;
    caddy) printf 'caddy' ;;
    docker-proxy|dockerd)
      if printf '%s' "$dname" | grep -q 'caddy'; then
        printf 'other-caddy-container'
      else
        printf 'other-docker'
      fi
      ;;
    xray|v2ray|sing-box|x-ui|x-ui-*) printf 'panel-stack' ;;
    *) printf 'other' ;;
  esac
}

find_nginx_dir() {
  if command -v nginx >/dev/null 2>&1; then
    dump="$(nginx -T 2>/dev/null || true)"
    if printf '%s' "$dump" | grep -q '/etc/nginx/conf.d'; then
      printf '/etc/nginx/conf.d'
      return 0
    fi
    if printf '%s' "$dump" | grep -q '/etc/nginx/sites-enabled'; then
      printf '/etc/nginx/sites-enabled'
      return 0
    fi
  fi
  for d in /etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf/conf.d; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  if [ -d /etc/nginx/conf.d ]; then
    printf '/etc/nginx/conf.d'
    return 0
  fi
  printf ''
}

find_host_caddyfile() {
  for f in /etc/caddy/Caddyfile /usr/local/etc/caddy/Caddyfile /opt/caddy/Caddyfile; do
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  printf ''
}

detect() {
  load_dotenv
  http_info="$(owner_of_port 80)"
  https_info="$(owner_of_port 443)"
  http_proc="${http_info%%|*}"
  rest="${http_info#*|}"
  http_pid="${rest%%|*}"
  http_docker="${rest#*|}"
  https_proc="${https_info%%|*}"
  rest443="${https_info#*|}"
  https_pid="${rest443%%|*}"
  https_docker="${rest443#*|}"

  http_class="$(classify_owner "$http_proc" "$http_docker")"
  https_class="$(classify_owner "$https_proc" "$https_docker")"

  mode="direct"
  reason="80/443 空闲，由镜像站 Caddy 对外并自动签证书"

  if [ -n "${ADAPT_FORCE_MODE:-}" ]; then
    mode="$ADAPT_FORCE_MODE"
    reason="手动指定 ADAPT_FORCE_MODE=$ADAPT_FORCE_MODE"
  else
    case "$http_class" in
      free|self-caddy)
        if [ "$https_class" = "free" ] || [ "$https_class" = "self-caddy" ]; then
          mode="direct"
          reason="80/443 空闲或已是本站 Caddy"
        elif [ "$https_class" = "nginx" ]; then
          mode="behind-nginx"
          reason="443 已被 Nginx 占用，改为挂到现有 Nginx 后面"
        elif [ "$https_class" = "caddy" ]; then
          mode="behind-caddy"
          reason="443 已被宿主机 Caddy 占用，改为写入现有 Caddyfile"
        else
          mode="direct"
          reason="80 空闲，443 被 ${https_proc:-unknown} 占用；先占 80 做 HTTP-01，443 若冲突会再降级"
        fi
        ;;
      nginx)
        mode="behind-nginx"
        reason="80 已被 Nginx(pid=${http_pid:-?}) 占用"
        ;;
      caddy)
        mode="behind-caddy"
        reason="80 已被宿主机 Caddy(pid=${http_pid:-?}) 占用"
        ;;
      other-caddy-container)
        mode="behind-unknown"
        reason="80 已被其他 Caddy 容器 ${http_docker} 占用，不能安全改写"
        ;;
      other-docker)
        mode="behind-unknown"
        reason="80 已被 Docker 容器 ${http_docker:-?} 占用"
        ;;
      panel-stack)
        mode="behind-unknown"
        reason="80 已被 ${http_proc} 占用（面板/代理栈）。若前面还有 Nginx，请把 80 交给 Nginx"
        ;;
      *)
        mode="behind-unknown"
        reason="80 已被 ${http_proc:-unknown} 占用"
        ;;
    esac
  fi

  SITE_ADDRESS="${SITE_ADDRESS:-docker.nodelink.uk}"
  DOMAIN="${DOMAIN:-}"
  ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"

  emit MODE "$mode"
  emit REASON "$reason"
  emit SITE_ADDRESS "$SITE_ADDRESS"
  emit DOMAIN "$DOMAIN"
  emit ACME_EMAIL "$ACME_EMAIL"
  emit HTTP80_PROC "$http_proc"
  emit HTTP80_PID "$http_pid"
  emit HTTP80_DOCKER "$http_docker"
  emit HTTP80_CLASS "$http_class"
  emit HTTP443_PROC "$https_proc"
  emit HTTP443_PID "$https_pid"
  emit HTTP443_DOCKER "$https_docker"
  emit HTTP443_CLASS "$https_class"
  emit NGINX_BIN "$(command -v nginx 2>/dev/null || true)"
  emit CADDY_BIN "$(command -v caddy 2>/dev/null || true)"
  emit NGINX_DIR "$(find_nginx_dir)"
  emit HOST_CADDYFILE "$(find_host_caddyfile)"
  emit BACKEND "127.0.0.1:${BACKEND_PORT}"
}

save_detect() {
  detect > "$STATE_FILE"
  # shellcheck disable=SC1090
  if ! . "$STATE_FILE"; then
    log "探测结果无法加载，原文如下："
    cat "$STATE_FILE" >&2 || true
    fail "探测状态文件语法错误"
  fi
  log "== 主机探测 =="
  log "80  : ${HTTP80_PROC:-none} pid=${HTTP80_PID:--} docker=${HTTP80_DOCKER:--} class=${HTTP80_CLASS:-}"
  log "443 : ${HTTP443_PROC:-none} pid=${HTTP443_PID:--} docker=${HTTP443_DOCKER:--} class=${HTTP443_CLASS:-}"
  log "决策: $MODE"
  log "原因: $REASON"
}

configure() {
  load_dotenv
  save_detect
  # shellcheck disable=SC1090
  . "$STATE_FILE"

  case "$MODE" in
    direct)
      set_env HTTP_ONLY false
      set_env HTTP_BIND 0.0.0.0
      set_env HTTP_PORT 80
      set_env HTTPS_BIND 0.0.0.0
      set_env HTTPS_PORT 443
      log "已写入 .env：镜像站直连 0.0.0.0:80/443"
      ;;
    behind-nginx|behind-caddy|behind-unknown)
      set_env HTTP_ONLY true
      set_env HTTP_BIND 127.0.0.1
      set_env HTTP_PORT "$BACKEND_PORT"
      set_env HTTPS_BIND 127.0.0.1
      set_env HTTPS_PORT 5443
      log "已写入 .env：镜像站仅本机 127.0.0.1:${BACKEND_PORT}（HTTP_ONLY=true，不抢 80/443）"
      ;;
    *)
      fail "未知模式 $MODE"
      ;;
  esac
}

upsert_marked_file() {
  dest="$1"
  body_file="$2"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && grep -q "$MARKER_BEGIN" "$dest"; then
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v bodyfile="$body_file" '
      $0 == begin {while ((getline line < bodyfile) > 0) print line; close(bodyfile); skip=1; next}
      $0 == end {skip=0; next}
      skip != 1 {print}
    ' "$dest" > "$tmp"
    mv "$tmp" "$dest"
  elif [ -f "$dest" ]; then
    printf '\n' >> "$dest"
    cat "$body_file" >> "$dest"
  else
    cat "$body_file" > "$dest"
  fi
}

nginx_http_only_server() {
  site="$1"
  cat <<EOF
$MARKER_BEGIN
server {
    listen 80;
    listen [::]:80;
    server_name ${site};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        client_max_body_size 0;
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
    }
}
$MARKER_END
EOF
}

nginx_ssl_server() {
  site="$1"
  cert="$2"
  key="$3"
  http2_mode="${4:-listen}"
  assert_pem_path "ssl_certificate" "$cert"
  assert_pem_path "ssl_certificate_key" "$key"

  listen443="listen 443 ssl;"
  listen4436="listen [::]:443 ssl;"
  http2_line=""
  if [ "$http2_mode" = "listen" ]; then
    listen443="listen 443 ssl http2;"
    listen4436="listen [::]:443 ssl http2;"
  elif [ "$http2_mode" = "on" ]; then
    http2_line="    http2 on;"
  fi

  cat <<EOF
$MARKER_BEGIN
server {
    listen 80;
    listen [::]:80;
    server_name ${site};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${listen443}
    ${listen4436}
${http2_line}
    server_name ${site};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};

    client_max_body_size 0;
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_connect_timeout 60;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
    }
}
$MARKER_END
EOF
}

count_ssl_tokens() {
  file="$1"
  awk '
    $1 == "ssl_certificate" {
      if (NF != 2) { print "bad-cert-nf=" NF; exit 1 }
      if ($2 !~ /^\//) { print "bad-cert-path"; exit 1 }
    }
    $1 == "ssl_certificate_key" {
      if (NF != 2) { print "bad-key-nf=" NF; exit 1 }
      if ($2 !~ /^\//) { print "bad-key-path"; exit 1 }
    }
    END { print "ok" }
  ' "$file"
}

reload_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    fail "找不到 nginx 命令"
  fi
  if ! nginx -t >/tmp/docker-mirror-nginx-t.out 2>&1; then
    cat /tmp/docker-mirror-nginx-t.out >&2
    fail "nginx -t 失败，未 reload"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    nginx -s reload
  fi
  log "Nginx 已 reload"
}

# 写入 dest：先校验 ssl 行，再替换；nginx -t 失败则回滚并返回 1
install_nginx_conf() {
  dest="$1"
  src="$2"
  check="$(count_ssl_tokens "$src")"
  if [ "$check" != "ok" ]; then
    log "生成的 Nginx 配置非法（$check），拒绝覆盖 $dest"
    return 1
  fi
  bak="${dest}.ok"
  # 坏掉的 ssl_certificate 不能当成回滚底稿（v1.0.4 线上就是这种文件）
  if [ -f "$dest" ] && [ "$(count_ssl_tokens "$dest")" = "ok" ]; then
    cp "$dest" "$bak"
  fi
  cp "$src" "$dest"
  if ! nginx -t >/tmp/docker-mirror-nginx-t.out 2>&1; then
    cat /tmp/docker-mirror-nginx-t.out >&2
    log "新配置未通过 nginx -t，正在回滚"
    if [ -f "$bak" ]; then
      cp "$bak" "$dest"
    else
      rm -f "$dest"
    fi
    nginx -t >/dev/null 2>&1 || true
    return 1
  fi
  reload_nginx
}

ensure_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    return 0
  fi
  log "未找到 certbot，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >&2
    apt-get install -y certbot >&2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y certbot >&2
  elif command -v yum >/dev/null 2>&1; then
    yum install -y certbot >&2
  else
    fail "无法自动安装 certbot，请先手动安装"
  fi
  command -v certbot >/dev/null 2>&1 || fail "certbot 安装后仍找不到命令"
}

write_live_file() {
  live="$1"
  assert_pem_path "证书目录" "$live"
  printf '%s\n' "$live" > "$CERT_LIVE_FILE"
}

read_live_file() {
  [ -f "$CERT_LIVE_FILE" ] || fail "没有证书目录记录 $CERT_LIVE_FILE"
  live="$(tr -d '\r' < "$CERT_LIVE_FILE" | sed -n '/^\/etc\/letsencrypt\/live\/[A-Za-z0-9._-]*$/p' | tail -n1)"
  [ -n "$live" ] || fail "证书目录记录损坏：$CERT_LIVE_FILE"
  printf '%s' "$live"
}

issue_cert_webroot() {
  site="$1"
  email="$2"
  live="/etc/letsencrypt/live/${site}"

  if [ -f "$live/fullchain.pem" ] && [ -f "$live/privkey.pem" ]; then
    log "已有证书 $live ，复用"
    write_live_file "$live"
    return 0
  fi

  ensure_certbot
  mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
  # 给 ACME 探活一个可写探测文件
  printf 'ok\n' > "$ACME_WEBROOT/.well-known/acme-challenge/.docker-mirror-ready"

  log "正在为 ${site} 申请 Let's Encrypt 证书（webroot=${ACME_WEBROOT}）..."
  if ! certbot certonly --webroot -w "$ACME_WEBROOT" \
    -d "$site" \
    -m "$email" \
    --agree-tos --no-eff-email --non-interactive >&2; then
    fail "certbot 申请失败。请确认 http://${site}/.well-known/acme-challenge/ 能打到这台机器，且 Cloudflare 为灰云"
  fi
  [ -f "$live/fullchain.pem" ] && [ -f "$live/privkey.pem" ] || fail "证书申请失败：$live 下没有 pem"
  write_live_file "$live"
}

write_ssl_variants() {
  site="$1"
  cert="$2"
  key="$3"
  dest="$4"
  tmp="$(mktemp)"
  ok=0
  last_err=""
  for mode in listen on off; do
    nginx_ssl_server "$site" "$cert" "$key" "$mode" > "$tmp"
    check="$(count_ssl_tokens "$tmp")"
    if [ "$check" != "ok" ]; then
      last_err="ssl 行校验失败：$check"
      continue
    fi
    if install_nginx_conf "$dest" "$tmp"; then
      ok=1
      log "HTTPS 站点已加载（http2=${mode}）"
      break
    fi
    last_err="nginx -t 未通过（http2=${mode}）"
    log "$last_err，尝试下一种写法"
  done
  rm -f "$tmp"
  [ "$ok" -eq 1 ] || fail "三种 HTTP/2 写法都无法通过 nginx -t${last_err:+；}${last_err}"
}

integrate_nginx() {
  load_dotenv
  site="${SITE_ADDRESS:?SITE_ADDRESS 为空}"
  email="${ACME_EMAIL:-admin@example.com}"
  dir="$(find_nginx_dir)"
  [ -n "$dir" ] || fail "找不到可写的 Nginx 配置目录"
  dest="$dir/docker-mirror.conf"
  mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"

  if [ ! -w "$dir" ]; then
    fail "没有权限写入 $dir ，请用 root 跑部署"
  fi

  case "$site" in
    *[!A-Za-z0-9.-]*|"") fail "SITE_ADDRESS 非法：$site" ;;
  esac

  log "写入 Nginx HTTP 站点（先保证 ACME 和本机反代）：$dest"
  http_tmp="$(mktemp)"
  nginx_http_only_server "$site" > "$http_tmp"
  if ! install_nginx_conf "$dest" "$http_tmp"; then
    rm -f "$http_tmp"
    fail "写入 HTTP 站点后 nginx -t 失败"
  fi
  rm -f "$http_tmp"

  if ! curl -fsS --connect-timeout 5 "http://127.0.0.1:${BACKEND_PORT}/healthz" >/dev/null 2>&1; then
    fail "本机 127.0.0.1:${BACKEND_PORT}/healthz 不通，先确认 compose 已起来"
  fi

  issue_cert_webroot "$site" "$email"
  live="$(read_live_file)"
  cert="${live}/fullchain.pem"
  key="${live}/privkey.pem"
  assert_pem_file "ssl_certificate" "$cert"
  assert_pem_file "ssl_certificate_key" "$key"

  log "写入 Nginx HTTPS 站点，证书=${cert}"
  write_ssl_variants "$site" "$cert" "$key" "$dest"
  log "Nginx 已启用 HTTPS → 127.0.0.1:${BACKEND_PORT}"
}

caddy_site_block() {
  site="$1"
  cat <<EOF
$MARKER_BEGIN
${site} {
	reverse_proxy 127.0.0.1:${BACKEND_PORT} {
		flush_interval -1
		transport http {
			read_timeout 1h
			write_timeout 1h
		}
	}
}
$MARKER_END
EOF
}

reload_host_caddy() {
  file="$1"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^caddy'; then
    systemctl reload caddy || systemctl restart caddy
    log "宿主机 Caddy 已 reload"
    return 0
  fi
  if command -v caddy >/dev/null 2>&1; then
    caddy reload --config "$file" || caddy run --config "$file" &
    log "已执行 caddy reload --config $file"
    return 0
  fi
  fail "找不到宿主机 Caddy 服务"
}

integrate_caddy() {
  load_dotenv
  site="${SITE_ADDRESS:?SITE_ADDRESS 为空}"
  file="$(find_host_caddyfile)"
  [ -n "$file" ] || fail "找不到宿主机 Caddyfile"
  [ -w "$file" ] || fail "没有权限写 $file"
  cp "$file" "${file}.bak.docker-mirror.$(date +%Y%m%d%H%M%S)"
  body="$(mktemp)"
  caddy_site_block "$site" > "$body"
  upsert_marked_file "$file" "$body"
  rm -f "$body"
  reload_host_caddy "$file"
  log "已把 ${site} 写入 $file ，证书由宿主机 Caddy 签发"
}

verify_public() {
  load_dotenv
  site="${SITE_ADDRESS:?}"
  log "== 验收 =="
  if curl -fsS --connect-timeout 5 "http://127.0.0.1:${HTTP_PORT:-$BACKEND_PORT}/healthz" >/dev/null 2>&1; then
    log "  [OK] 本机 http://127.0.0.1:${HTTP_PORT:-$BACKEND_PORT}/healthz"
  else
    fail "本机健康检查失败"
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 25 "https://${site}/healthz" || true)"
  if [ "$code" = "200" ]; then
    log "  [OK] https://${site}/healthz"
    return 0
  fi
  log "  [WAIT] https://${site}/healthz HTTP ${code:-timeout}（证书可能还在签发）"
  i=0
  while [ "$i" -lt 18 ]; do
    i=$((i + 1))
    sleep 5
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 "https://${site}/healthz" || true)"
    if [ "$code" = "200" ]; then
      log "  [OK] https://${site}/healthz"
      return 0
    fi
    log "  ... 第 ${i} 次：HTTP ${code:-timeout}"
  done
  fail "公网 https://${site}/healthz 仍未通过。请看现有反代是否已加载 ${site}"
}

integrate() {
  load_dotenv
  if [ ! -f "$STATE_FILE" ]; then
    save_detect
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  save_detect
  # shellcheck disable=SC1090
  . "$STATE_FILE"

  case "$MODE" in
    direct)
      log "直连模式：证书由镜像站 Caddy 申请，无需改 Nginx"
      verify_public || true
      if ! curl -fsS --connect-timeout 15 "https://${SITE_ADDRESS}/healthz" >/dev/null 2>&1; then
        log "直连签证书尚未完成，看： docker compose logs caddy --tail=80"
      fi
      ;;
    behind-nginx)
      integrate_nginx
      verify_public
      ;;
    behind-caddy)
      integrate_caddy
      verify_public
      ;;
    behind-unknown)
      log "无法安全自动改写占用 80 的进程（${HTTP80_PROC:-unknown} ${HTTP80_DOCKER}）。"
      log "镜像站已在 127.0.0.1:${BACKEND_PORT} 就绪。请把下面片段交给占用 80 的软件："
      log ""
      log "Nginx:"
      nginx_http_only_server "${SITE_ADDRESS}" >&2
      log ""
      log "Caddy:"
      caddy_site_block "${SITE_ADDRESS}" >&2
      fail "80 被未知进程占用，已准备好后端，但没有自动改反代"
      ;;
  esac
}

all() {
  configure
  log "configure 完成。请先 docker compose up，再执行 integrate。"
}

gen_nginx_ssl() {
  site="${1:-}"
  cert="${2:-}"
  key="${3:-}"
  [ -n "$site" ] && [ -n "$cert" ] && [ -n "$key" ] || fail "用法: $0 gen-nginx-ssl <site> <fullchain> <privkey>"
  nginx_ssl_server "$site" "$cert" "$key" "listen"
}

case "$PHASE" in
  detect) detect ;;
  configure) configure ;;
  integrate) integrate ;;
  all) all ;;
  gen-nginx-ssl) gen_nginx_ssl "${2:-}" "${3:-}" "${4:-}" ;;
  *)
    echo "用法: $0 detect|configure|integrate|all|gen-nginx-ssl" >&2
    exit 1
    ;;
esac
