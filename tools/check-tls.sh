#!/usr/bin/env bash
# Проверка почтовых портов снаружи: доступность, TLS, цепочка сертификата и имя.
# Запускать с внешней машины (или с самого шлюза). Нужен OpenSSL 1.1.1+ (STARTTLS для
# ManageSieve и -verify_hostname); на macOS — openssl из Homebrew, не LibreSSL.
#
# Использование: tools/check-tls.sh HOST [PORT...]
#   по умолчанию: 25 465 587 143 993 995 4190; порт 110 (POP3) — укажите явно, если публикуется.
# До переключения MX порт 25 открыт только для адресов из SMTP_ALLOWLIST.
#
# Код выхода: 0 — на всех портах "Verify return code: 0", иначе 1.
set -uo pipefail   # без -e: проверяем все порты и печатаем сводку

host=${1:-}
if [ -z "$host" ] || [ "$host" = -h ] || [ "$host" = --help ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
shift
if [ $# -gt 0 ]; then ports=("$@"); else ports=(25 465 587 143 993 995 4190); fi

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"
  fi
}

rc=0
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
    printf '%-5s FAIL  нет TLS-соединения\n' "$p"
    printf '%s\n' "$out" | grep -Ei 'error|refused|timed out|unknown|errno' | head -n3 | sed 's/^/      /'
    rc=1
  elif printf '%s' "$verify" | grep -q 'code: 0 '; then
    printf '%-5s OK    %s | до %s\n' "$p" "$subject" "$enddate"
  else
    printf '%-5s FAIL  %s | %s\n' "$p" "$verify" "$subject"
    rc=1
  fi
done
exit $rc
