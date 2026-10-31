#!/usr/bin/env bash
# Проверка, что mailcow за шлюзом не стал open relay: SMTP-диалог без авторизации до RCPT TO
# на чужой домен. Письмо не отправляется — до DATA дело не доходит. Скрипт самодостаточен:
# его можно скопировать отдельно от репозитория.
set -uo pipefail

VERSION=0.1.0

usage() {
  cat <<'EOF'
Использование: tools/check-relay.sh HOST [FROM] [TO]

Проверка на open relay: SMTP-диалог без авторизации до RCPT TO на чужой домен.
Письмо не отправляется — до DATA дело не доходит.

Параметры:
  HOST         публичное имя или адрес шлюза (например, mail.example.com)
  FROM         отправитель, по умолчанию probe@example.org
  TO           получатель в чужом домене, по умолчанию probe@example.net
  -h, --help   эта справка
  --version    версия

Переменные окружения: PORT (по умолчанию 25), HELO (по умолчанию hostname -f),
NO_COLOR — без цвета.
До переключения MX порт 25 открыт только для адресов из SMTP_ALLOWLIST — запускайте оттуда.

Примеры:
  tools/check-relay.sh mail.example.com
  PORT=587 tools/check-relay.sh mail.example.com

Коды возврата: 0 — OK, relay запрещён ("Relay access denied"); 1 — WARN, проверка не дала
однозначного ответа (нет соединения, отказ не из-за relay); 2 — FAIL, OPEN RELAY;
64 — неверные аргументы.
EOF
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  --version) printf 'mailcow-edge-gateway %s\n' "$VERSION"; exit 0 ;;
  "") echo "ОШИБКА: не указан HOST (справка: $0 --help)" >&2; exit 64 ;;
  -*) echo "ОШИБКА: неизвестный параметр: $1 (справка: $0 --help)" >&2; exit 64 ;;
esac

# Цвет — только в терминале и без NO_COLOR (https://no-color.org).
GREEN="" YELLOW="" RED="" RESET=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
fi
ok()   { printf '%sOK%s    %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%sWARN%s  %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%sFAIL%s  %s\n' "$RED" "$RESET" "$*"; }

host=$1
from=${2:-probe@example.org}
to=${3:-probe@example.net}
port=${PORT:-25}
helo=${HELO:-$(hostname -f 2>/dev/null || hostname)}

# Отдельная проверка доступности с таймаутом: подключение через /dev/tcp само по себе может
# висеть минутами.
if command -v timeout >/dev/null 2>&1; then
  if ! timeout 15 bash -c ": <>/dev/tcp/$host/$port" 2>/dev/null; then
    warn "не удалось подключиться к $host:$port (до переключения MX — адрес не в SMTP_ALLOWLIST?)"
    exit 1
  fi
fi
if ! exec 3<>"/dev/tcp/$host/$port"; then
  warn "не удалось подключиться к $host:$port"
  exit 1
fi

CODE=""
TEXT=""
reply() {
  local line
  CODE=""
  TEXT=""
  while IFS= read -r -t 60 line <&3; do
    line=${line%$'\r'}
    printf '<<< %s\n' "$line"
    TEXT="$TEXT$line"$'\n'
    if [ "${line:3:1}" != "-" ]; then
      CODE=${line:0:3}
      return 0
    fi
  done
  warn "соединение закрыто или нет ответа (до переключения MX — адрес не в SMTP_ALLOWLIST?)"
  return 1
}
say() {
  printf '>>> %s\n' "$1"
  printf '%s\r\n' "$1" >&3
}
finish() {
  say "QUIT"
  reply >/dev/null 2>&1 || true
  exec 3<&-
  exit "$1"
}

# Приветствие ждём до первой команды: postscreen отклоняет клиентов, которые говорят раньше.
reply || exit 1
[ "$CODE" = 220 ] || { warn "сервер не принял соединение ($CODE)"; finish 1; }
say "EHLO $helo"
reply || exit 1
say "MAIL FROM:<$from>"
reply || exit 1
case $CODE in
  2*) ;;
  *) warn "MAIL FROM отклонён ($CODE) — проверка неоднозначна, попробуйте другой FROM"; finish 1 ;;
esac
say "RCPT TO:<$to>"
reply || exit 1
rcpt_code=$CODE
rcpt_text=$TEXT
say "RSET"
reply || true

echo
case $rcpt_code in
  2*)
    fail "OPEN RELAY: RCPT на чужой домен принят без авторизации ($rcpt_code)."
    echo "      Проверьте барьеры из модели угроз: nftables на бэкенде и шлюзе, deny-src в HAProxy,"
    echo "      userland-proxy Docker (https://pugemon.github.io/mailcow-edge-gateway/threat-model/)."
    finish 2
    ;;
esac
if printf '%s' "$rcpt_text" | grep -qi 'relay access denied'; then
  ok "relay запрещён ($rcpt_code Relay access denied)"
  finish 0
fi
warn "RCPT отклонён ($rcpt_code), но не из-за relay — разберите ответ вручную"
finish 1
