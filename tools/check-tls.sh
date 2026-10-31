#!/usr/bin/env bash
# Проверка почтовых портов снаружи: доступность, TLS, цепочка сертификата, имя и срок действия.
# Запускать с внешней машины (или с самого шлюза). Скрипт самодостаточен: его можно скопировать
# отдельно от репозитория.
set -uo pipefail   # без -e: проверяем все порты и печатаем сводку

VERSION=0.1.0
DEFAULT_PORTS="25 465 587 143 993 995 4190"

usage() {
  cat <<EOF
Использование: tools/check-tls.sh [--warn-days N] HOST [PORT...]

Проверка TLS на почтовых портах: соединение (STARTTLS там, где он нужен), цепочка сертификата,
имя HOST в сертификате, срок действия. Нужен OpenSSL 1.1.1+ (STARTTLS для ManageSieve,
-verify_hostname); на macOS — openssl из Homebrew, не LibreSSL.

Параметры:
  HOST            публичное имя mailcow (например, mail.example.com)
  PORT...         порты (по умолчанию: $DEFAULT_PORTS);
                  110 (POP3) — укажите явно, если публикуется
  --warn-days N   WARN, если сертификат истекает раньше чем через N дней (по умолчанию 14)
  -h, --help      эта справка
  --version       версия

До переключения MX порт 25 открыт только для адресов из SMTP_ALLOWLIST — запускайте оттуда.

Примеры:
  tools/check-tls.sh mail.example.com
  tools/check-tls.sh mail.example.com 25 587
  NO_COLOR=1 tools/check-tls.sh mail.example.com > report.txt

Вывод: строка на порт — OK, WARN (скоро истекает) или FAIL; цвет — только в терминале
и без NO_COLOR.
Коды возврата: 0 — на всех портах OK или WARN, 1 — есть FAIL, 64 — неверные аргументы.
EOF
}

warn_days=14
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --version) printf 'mailcow-edge-gateway %s\n' "$VERSION"; exit 0 ;;
    --warn-days)
      if [ $# -lt 2 ] || ! [[ $2 =~ ^[0-9]+$ ]]; then
        echo "ОШИБКА: --warn-days: нужно число дней" >&2; exit 64
      fi
      warn_days=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "ОШИБКА: неизвестный параметр: $1 (справка: $0 --help)" >&2; exit 64 ;;
    *) break ;;
  esac
done

host=${1:-}
if [ -z "$host" ]; then
  echo "ОШИБКА: не указан HOST (справка: $0 --help)" >&2
  exit 64
fi
shift
if [ $# -gt 0 ]; then
  ports=("$@")
else
  # shellcheck disable=SC2206  # список портов без пробелов внутри
  ports=($DEFAULT_PORTS)
fi
for p in "${ports[@]}"; do
  [[ $p =~ ^[0-9]{1,5}$ ]] || { echo "ОШИБКА: некорректный порт: $p" >&2; exit 64; }
done

# Цвет — только в терминале и без NO_COLOR (https://no-color.org).
GREEN="" YELLOW="" RED="" RESET=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
fi
status() {   # status OK|WARN|FAIL PORT TEXT
  local color=$GREEN
  case $1 in WARN) color=$YELLOW ;; FAIL) color=$RED ;; esac
  printf '%-5s %s%-4s%s  %s\n' "$2" "$color" "$1" "$RESET" "$3"
}

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"
  fi
}

rc=0
n_ok=0 n_warn=0 n_fail=0
for p in "${ports[@]}"; do
  case $p in
    25|587) st=(-starttls smtp) ;;
    143) st=(-starttls imap) ;;
    110) st=(-starttls pop3) ;;
    4190) st=(-starttls sieve) ;;
    *) st=() ;;
  esac
  out=$(with_timeout 20 openssl s_client -connect "$host:$p" -servername "$host" \
    -verify_hostname "$host" ${st[@]+"${st[@]}"} </dev/null 2>&1)
  verify=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*Verify return code:' | tail -n1 | sed 's/^[[:space:]]*//')
  subject=$(printf '%s\n' "$out" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//')
  enddate=$(printf '%s\n' "$out" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  if [ -z "$verify" ]; then
    status FAIL "$p" "нет TLS-соединения"
    printf '%s\n' "$out" | grep -Ei 'error|refused|timed out|unknown|errno' | head -n3 | sed 's/^/      /'
    rc=1; n_fail=$((n_fail + 1))
  elif printf '%s' "$verify" | grep -q 'code: 0 '; then
    if printf '%s\n' "$out" | openssl x509 -noout -checkend $((warn_days * 86400)) >/dev/null 2>&1; then
      status OK "$p" "$subject | до $enddate"
      n_ok=$((n_ok + 1))
    else
      status WARN "$p" "$subject | истекает $enddate (меньше $warn_days дн.)"
      n_warn=$((n_warn + 1))
    fi
  else
    status FAIL "$p" "$verify | $subject"
    rc=1; n_fail=$((n_fail + 1))
  fi
done
printf 'итого: OK %d, WARN %d, FAIL %d\n' "$n_ok" "$n_warn" "$n_fail"
exit $rc
