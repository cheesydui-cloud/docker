#!/usr/bin/env sh
# 给面板用的证书 / 站点探测。只输出 KEY=value。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  . ./.env
  set +a
fi

SITE_ADDRESS="${SITE_ADDRESS:-}"
HTTP_PORT="${HTTP_PORT:-5080}"
EDGE_MODE="${EDGE_MODE:-}"

kv() { printf '%s=%s\n' "$1" "$2"; }

kv site "$SITE_ADDRESS"
kv edge_mode "$EDGE_MODE"
kv backend_port "$HTTP_PORT"

if curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:${HTTP_PORT}/healthz" >/dev/null 2>&1; then
  kv backend ok
else
  kv backend down
fi

pub="fail"
if [ -n "$SITE_ADDRESS" ] && [ "$SITE_ADDRESS" != ":80" ]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 --max-redirs 0 "https://${SITE_ADDRESS}/healthz" || true)"
  kv public_https_code "${code:-000}"
  if [ "$code" = "200" ]; then
    pub="ok"
  elif [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "307" ] || [ "$code" = "308" ]; then
    pub="redirect"
  fi
else
  kv public_https_code ""
fi
kv public_https "$pub"

issuer=""
subject=""
not_after=""
if [ -n "$SITE_ADDRESS" ] && command -v openssl >/dev/null 2>&1; then
  dump="$(echo | openssl s_client -servername "$SITE_ADDRESS" -connect "${SITE_ADDRESS}:443" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null || true)"
  subject="$(printf '%s\n' "$dump" | sed -n 's/^subject=//p' | head -n1)"
  issuer="$(printf '%s\n' "$dump" | sed -n 's/^issuer=//p' | head -n1)"
  not_after="$(printf '%s\n' "$dump" | sed -n 's/^notAfter=//p' | head -n1)"
fi
kv cert_subject "$subject"
kv cert_issuer "$issuer"
kv cert_not_after "$not_after"

live=""
for d in \
  "/etc/letsencrypt/live/${SITE_ADDRESS}" \
  "/root/cert/${SITE_ADDRESS}"
do
  if [ -f "$d/fullchain.pem" ] || [ -f "$d/fullchain.cer" ]; then
    live="$d"
    break
  fi
done
kv cert_live "$live"

trusted="no"
case "$issuer" in
  *Lets\ Encrypt*|*Let?s\ Encrypt*|*YE1*|*YE2*|*R3*|*E5*|*E6*|*ISRG*)
    trusted="yes"
    ;;
esac
printf '%s' "$issuer" | grep -Eq "Let.s Encrypt|Lets Encrypt" && trusted="yes"
if [ "$pub" = "ok" ] && [ "$trusted" = "yes" ]; then
  kv cert_ok yes
elif [ "$pub" = "ok" ]; then
  kv cert_ok maybe
else
  kv cert_ok no
fi
