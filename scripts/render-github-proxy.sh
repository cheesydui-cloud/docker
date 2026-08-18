#!/usr/bin/env sh
# 根据 .env 生成 tinyproxy 配置。不启停容器。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  . ./.env
  set +a
fi

TPL="${ROOT}/proxy/tinyproxy.conf.tpl"
OUT="${ROOT}/proxy/tinyproxy.conf"
mkdir -p "${ROOT}/proxy"

if [ ! -f "$TPL" ]; then
  printf 'ERROR: 缺少 %s\n' "$TPL" >&2
  exit 1
fi

tmp="$(mktemp)"
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = '# {{ALLOW_LINES}}' ]; then
    raw="${GITHUB_PROXY_ALLOW:-}"
    raw="$(printf '%s' "$raw" | tr ',;' '  ' | tr '\n' ' ')"
    for item in $raw; do
      case "$item" in
        ""|\#*) continue ;;
      esac
      printf 'Allow %s\n' "$item"
    done
  else
    printf '%s\n' "$line"
  fi
done < "$TPL" > "$tmp"
mv "$tmp" "$OUT"
printf '已生成 proxy/tinyproxy.conf\n'
