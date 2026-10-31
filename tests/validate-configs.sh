#!/usr/bin/env bash
# Проверка синтаксиса отрендеренных конфигов настоящими haproxy и nft: примеры настроек
# (examples/*.conf) и варианты — после переключения MX, все сервисы, дополнительные сети deny-src.
#
#   haproxy -c   нужен haproxy и пользователь haproxy (ставится вместе с пакетом);
#   nft -c       нужен root (проверка идёт через netlink ядра, таблицы не загружаются).
#
# Чего нет — пропускается; STRICT=1 превращает пропуск в ошибку (так запускается в CI).
# Запуск: make validate (или sudo STRICT=1 tests/validate-configs.sh).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/meg-validate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STRICT=${STRICT:-0}
FAILED=0
CHECKED=0

ok()   { printf 'ok    %s\n' "$*"; CHECKED=$((CHECKED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
skip() {
  if [ "$STRICT" = 1 ]; then fail "$* (STRICT=1)"; else printf 'skip  %s\n' "$*"; fi
}

# Варианты настроек шлюза: имя и строки, дописанные к examples/gateway.conf.
render_gateway() {   # render_gateway NAME [KEY=VALUE...]
  local name=$1 conf=$TMP/$1.conf
  shift
  cp "$ROOT/examples/gateway.conf" "$conf"
  printf '%s\n' "$@" >> "$conf"
  "$ROOT/gateway/install.sh" -c "$conf" --render "$TMP/$name" >/dev/null ||
    { fail "рендер шлюза ($name)"; return 1; }
}

render_gateway gateway-default
render_gateway gateway-open SMTP_ALLOWLIST_ENABLED=no \
  'SERVICES="smtp smtps submission imap imaps pop3 pop3s sieve"' \
  'HAPROXY_DENY_SRC_EXTRA="203.0.113.128/25 198.51.100.9"' OVERLAY_SERVICE=
"$ROOT/backend/install.sh" -c "$ROOT/examples/backend.conf" --render "$TMP/backend" >/dev/null ||
  fail "рендер бэкенда"

# haproxy -c: пути к спискам в haproxy.cfg абсолютные — подставляем отрендеренные копии
# (так же делает gateway/install.sh перед установкой).
if command -v haproxy >/dev/null 2>&1 && id haproxy >/dev/null 2>&1; then
  for v in gateway-default gateway-open; do
    cfg=$TMP/$v/etc/haproxy/haproxy.cfg
    sed "s#/etc/haproxy/#$TMP/$v/etc/haproxy/#g" "$cfg" > "$TMP/$v-check.cfg"
    if out=$(haproxy -c -f "$TMP/$v-check.cfg" 2>&1); then
      ok "haproxy -c ($v)"
    else
      fail "haproxy -c ($v)"
      printf '%s\n' "$out" | sed 's/^/        | /'
    fi
  done
else
  skip "haproxy -c: нет haproxy или пользователя haproxy"
fi

# nft -c: проверка без загрузки таблиц.
if command -v nft >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  for f in gateway-default/etc/mail-edge.nft gateway-open/etc/mail-edge.nft backend/etc/mailcow-edge.nft; do
    if out=$(nft -c -f "$TMP/$f" 2>&1); then
      ok "nft -c ($f)"
    else
      fail "nft -c ($f)"
      printf '%s\n' "$out" | sed 's/^/        | /'
    fi
  done
else
  skip "nft -c: нужны nft и root"
fi

echo
echo "итого: проверено $CHECKED, ошибок $FAILED"
[ "$FAILED" = 0 ]
