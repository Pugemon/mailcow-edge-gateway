#!/usr/bin/env bash
# Проверка, что mailcow за шлюзом не стал open relay: SMTP-диалог без авторизации до RCPT TO
# на чужой домен. Письмо не отправляется — до DATA дело не доходит.
#
# Использование: tools/check-relay.sh HOST [FROM] [TO]
#   HOST  публичное имя или адрес шлюза (например, mail.example.com)
#   FROM  отправитель, по умолчанию probe@example.org
#   TO    получатель в чужом домене, по умолчанию probe@example.net
# Переменные окружения: PORT (по умолчанию 25), HELO (по умолчанию hostname -f).
# До переключения MX порт 25 открыт только для адресов из SMTP_ALLOWLIST — запускайте оттуда.
#
# Код выхода: 0 — "Relay access denied"; 2 — OPEN RELAY; 1 — проверка не дала однозначного ответа.
set -uo pipefail

host=${1:-}
if [ -z "$host" ] || [ "$host" = -h ] || [ "$host" = --help ]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
from=${2:-probe@example.org}
to=${3:-probe@example.net}
port=${PORT:-25}
helo=${HELO:-$(hostname -f 2>/dev/null || hostname)}

# Отдельная проверка доступности с таймаутом: подключение через /dev/tcp само по себе может
# висеть минутами.
if command -v timeout >/dev/null 2>&1; then
  if ! timeout 15 bash -c ": <>/dev/tcp/$host/$port" 2>/dev/null; then
    echo "не удалось подключиться к $host:$port (до переключения MX — адрес не в SMTP_ALLOWLIST?)"
    exit 1
  fi
fi
if ! exec 3<>"/dev/tcp/$host/$port"; then
  echo "не удалось подключиться к $host:$port"
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
  echo "соединение закрыто или нет ответа (до переключения MX — адрес не в SMTP_ALLOWLIST?)"
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
[ "$CODE" = 220 ] || { echo "сервер не принял соединение ($CODE)"; finish 1; }
say "EHLO $helo"
reply || exit 1
say "MAIL FROM:<$from>"
reply || exit 1
case $CODE in
  2*) ;;
  *) echo "MAIL FROM отклонён ($CODE) — проверка неоднозначна, попробуйте другой FROM"; finish 1 ;;
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
    echo "ОПАСНО: RCPT на чужой домен принят без авторизации — OPEN RELAY."
    echo "Проверьте барьеры из docs/design.md (nftables на бэкенде и шлюзе, deny-src в HAProxy, userland-proxy)."
    finish 2
    ;;
esac
if printf '%s' "$rcpt_text" | grep -qi 'relay access denied'; then
  echo "OK: relay запрещён ($rcpt_code Relay access denied)"
  finish 0
fi
echo "RCPT отклонён ($rcpt_code), но не из-за relay — разберите ответ вручную"
finish 1
