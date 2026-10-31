#!/usr/bin/env bash
# Тесты без root и без внешней сети: функции lib/common.sh, рендер шаблонов на примерах
# конфигов, планы (--dry-run) установочных скриптов, разбор аргументов, коды возврата
# и проверки tools/ против локального фейкового SMTP-сервера.
#
# Запуск: make test (или tests/run.sh). Совместимо с bash 3.2.
#
# Регулярные выражения и шаблоны ниже содержат буквальные $VAR из конфигов nftables и compose.
# shellcheck disable=SC2016
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/meg-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export NO_COLOR=1
cd "$ROOT" || exit 1

PASS=0
FAILED=0
OUT=$TMP/out

t_ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
t_fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -s "$OUT" ]; then tail -n 15 "$OUT" | sed 's/^/        | /'; fi
}

# run_rc NAME RC CMD... — команда завершается с кодом RC; вывод (stdout+stderr) — в $OUT.
run_rc() {
  local name=$1 want=$2 rc=0
  shift 2
  "$@" >"$OUT" 2>&1 </dev/null || rc=$?
  if [ "$rc" = "$want" ]; then t_ok "$name"; else t_fail "$name: код $rc, ожидался $want"; fi
}

# expect NAME REGEX [FILE] — в FILE (по умолчанию — вывод последней команды) есть строка.
expect() {
  if grep -Eq -- "$2" "${3:-$OUT}"; then t_ok "$1"; else t_fail "$1: нет /$2/ в ${3:-выводе}"; fi
}

# expect_no NAME REGEX [FILE] — такой строки нет.
expect_no() {
  if grep -Eq -- "$2" "${3:-$OUT}"; then t_fail "$1: лишнее /$2/ в ${3:-выводе}"; else t_ok "$1"; fi
}

# $LIB CMD... — выполнить функцию CMD из lib/common.sh (или из помощников ниже) в отдельном
# процессе bash: как в установочных скриптах, с set -euo pipefail.
export TEST_TMP=$TMP
cat > "$TMP/helpers.sh" <<'EOF'
kv_case() { set_kv "$1" A 10; set_kv "$1" C 3; }
param_case() { set_param "$1" relayhost "[100.64.0.10]:2525"; set_param "$1" x_param y "# комментарий"; }
apply_three() {
  apply_file "$TEST_TMP/new-changed" "$TEST_TMP/fs/changed"
  apply_file "$TEST_TMP/new-same" "$TEST_TMP/fs/same"
  apply_file "$TEST_TMP/new-created" "$TEST_TMP/fs/sub/created" 0600
  printf 'CHANGED=%s\n' "$CHANGED"
  commit_changes
}
EOF
cat > "$TMP/lib" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$ROOT/lib/common.sh"
. "$TMP/helpers.sh"
"\$@"
EOF
chmod +x "$TMP/lib"
LIB=$TMP/lib

# conf_with SRC DST KEY=VALUE... — копия файла настроек с переопределёнными значениями.
conf_with() {
  local src=$1 dst=$2 kv
  shift 2
  cp "$src" "$dst"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$dst"; done
}

VERSION=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n1)

# ------------------------------------------------------------------ lib/common.sh
echo "== lib/common.sh"
run_rc "is_ipv4 192.0.2.1" 0 "$LIB" is_ipv4 192.0.2.1
run_rc "is_ipv4 256.0.0.1 — нет" 1 "$LIB" is_ipv4 256.0.0.1
run_rc "is_ipv4 192.0.2 — нет" 1 "$LIB" is_ipv4 192.0.2
run_rc "is_cidr4 198.51.100.0/24" 0 "$LIB" is_cidr4 198.51.100.0/24
run_rc "is_cidr4 /33 — нет" 1 "$LIB" is_cidr4 198.51.100.0/33
run_rc "is_cidr4 без маски — нет" 1 "$LIB" is_cidr4 198.51.100.7
run_rc "is_port 25" 0 "$LIB" is_port 25
run_rc "is_port 0 — нет" 1 "$LIB" is_port 0
run_rc "is_port 65536 — нет" 1 "$LIB" is_port 65536
run_rc "is_fqdn mail.example.com" 0 "$LIB" is_fqdn mail.example.com
run_rc "is_fqdn без точки — нет" 1 "$LIB" is_fqdn localhost
run_rc "is_fqdn с дефисом в начале — нет" 1 "$LIB" is_fqdn -mail.example.com
run_rc "is_ifname wg0" 0 "$LIB" is_ifname wg0
run_rc "is_ifname длиннее 15 — нет" 1 "$LIB" is_ifname abcdefghijklmnop

run_rc "port_list" 0 "$LIB" port_list 25 10 25 4190
expect "port_list: уникальные, по возрастанию" '^10, 25, 4190$'
run_rc "all_proxy_ports" 0 "$LIB" all_proxy_ports
expect "all_proxy_ports: все PROXY-порты" '^10025, 10110, 10143, 10465, 10587, 10993, 10995, 14190$'

printf 'A=1\nB=2' > "$TMP/kv"
run_rc "set_kv: замена и добавление" 0 "$LIB" kv_case "$TMP/kv"
expect "set_kv: A заменён" '^A=10$' "$TMP/kv"
expect "set_kv: C дописан с новой строки" '^C=3$' "$TMP/kv"
expect "set_kv: B не тронут" '^B=2$' "$TMP/kv"

printf 'relayhost = old\n' > "$TMP/cf"
run_rc "set_param: замена и добавление с комментарием" 0 "$LIB" param_case "$TMP/cf"
expect "set_param: relayhost заменён" '^relayhost = \[100\.64\.0\.10\]:2525$' "$TMP/cf"
expect "set_param: комментарий перед новым параметром" '^# комментарий$' "$TMP/cf"

printf 'a {{FOO}} b {{NOPE_VAR}}\n' > "$TMP/tmpl"
run_rc "render_template: незаданная переменная — ошибка" 1 \
  env FOO=x "$LIB" render_template "$TMP/tmpl" "$TMP/rendered"
expect "render_template: имя переменной в ошибке" 'NOPE_VAR'

# apply_file + commit_changes: очередь, подтверждение, резервные копии.
mkdir -p "$TMP/fs"
printf 'old\n' > "$TMP/fs/changed"
printf 'same\n' > "$TMP/fs/same"
printf 'new\n' > "$TMP/new-changed"
printf 'same\n' > "$TMP/new-same"
printf 'created\n' > "$TMP/new-created"
run_rc "commit_changes: без терминала и без --yes — отказ" 1 \
  env BACKUP_ROOT="$TMP/bak" "$LIB" apply_three
expect "commit_changes: подсказка про --yes" '--yes'
expect "commit_changes: план показан до вопроса" '^    \+new$'
if grep -qx old "$TMP/fs/changed" && [ ! -e "$TMP/fs/sub/created" ]; then
  t_ok "commit_changes: при отказе файлы не изменены"
else
  t_fail "commit_changes: при отказе файлы изменены"
fi
run_rc "commit_changes: --dry-run ничего не меняет" 0 \
  env DRY_RUN=1 BACKUP_ROOT="$TMP/bak" "$LIB" apply_three
expect "apply_file: счётчик изменений" '^CHANGED=2$'
if grep -qx old "$TMP/fs/changed"; then t_ok "dry-run: файл не изменён"; else t_fail "dry-run: файл изменён"; fi
run_rc "commit_changes: --yes устанавливает" 0 \
  env ASSUME_YES=1 BACKUP_ROOT="$TMP/bak" "$LIB" apply_three
expect "commit_changes: сообщение об обновлении" 'обновлён: .*/fs/changed'
if grep -qx new "$TMP/fs/changed" && grep -qx created "$TMP/fs/sub/created"; then
  t_ok "commit_changes: файлы установлены"
else
  t_fail "commit_changes: файлы не установлены"
fi
if [ -n "$(find "$TMP/bak" -name changed -exec grep -lx old {} \; 2>/dev/null)" ]; then
  t_ok "commit_changes: резервная копия старой версии"
else
  t_fail "commit_changes: нет резервной копии"
fi
if [ -n "$(find "$TMP/fs/sub/created" -perm 0600 2>/dev/null)" ]; then
  t_ok "commit_changes: права нового файла 0600"
else
  t_fail "commit_changes: права нового файла не 0600"
fi
run_rc "повторный запуск: нечего менять, вопроса нет" 0 \
  env BACKUP_ROOT="$TMP/bak" "$LIB" apply_three
expect "повторный запуск: CHANGED=0" '^CHANGED=0$'

# ------------------------------------------------------------------ шлюз: рендер
echo "== gateway/install.sh"
G=$TMP/gw
run_rc "gateway --render (examples/gateway.conf)" 0 gateway/install.sh -c examples/gateway.conf --render "$G"
for f in etc/haproxy/haproxy.cfg etc/haproxy/deny-src.lst etc/haproxy/smtp-allow.lst etc/mail-edge.nft \
  etc/systemd/system/mail-edge.service etc/systemd/system/haproxy.service.d/mail-edge.conf; do
  if [ -s "$G/$f" ]; then t_ok "gateway: $f"; else t_fail "gateway: нет $f"; fi
done
if grep -rq '{{' "$G"; then t_fail "gateway: остались {{...}}"; else t_ok "gateway: все переменные подставлены"; fi
H=$G/etc/haproxy/haproxy.cfg
expect "haproxy: listen smtp на публичном адресе" '^    bind 203\.0\.113\.10:25$' "$H"
expect "haproxy: PROXY v2 к бэкенду" '^    server mailcow 100\.64\.0\.20:10025 send-proxy-v2$' "$H"
expect "haproxy: deny-src на входах" 'tcp-request connection reject if \{ src -f /etc/haproxy/deny-src\.lst \}' "$H"
expect "haproxy: allowlist порта 25" 'reject if !\{ src -f /etc/haproxy/smtp-allow\.lst \}' "$H"
expect "haproxy: pop3s включён" '^listen pop3s$' "$H"
expect_no "haproxy: pop3 (110) по умолчанию выключен" '^listen pop3$' "$H"
expect "haproxy: таймаут IMAP" '^    timeout client 35m$' "$H"
expect "smtp-allow: адрес шлюза" '^203\.0\.113\.10/32$' "$G/etc/haproxy/smtp-allow.lst"
expect "smtp-allow: адрес из SMTP_ALLOWLIST с маской /32" '^198\.51\.100\.7/32$' "$G/etc/haproxy/smtp-allow.lst"
expect "deny-src: 100.64.0.0/10" '^100\.64\.0\.0/10$' "$G/etc/haproxy/deny-src.lst"
N=$G/etc/mail-edge.nft
expect "nft шлюза: адрес бэкенда" '^define BACKEND = 100\.64\.0\.20$' "$N"
expect "nft шлюза: только пользователь haproxy" 'meta skuid != "haproxy" counter reject' "$N"
expect "nft шлюза: транзит к PROXY-портам — drop" 'iifname != "wg0" ip daddr \$BACKEND tcp dport \{ 10025, 10110' "$N"
expect "nft шлюза: relay закрыт на публичном адресе" 'ip daddr 203\.0\.113\.10 tcp dport 2525 iifname != "lo" counter drop' "$N"
expect "drop-in HAProxy: после клиента оверлея" '^After=network-online\.target mail-edge\.service wg-quick@wg0\.service$' \
  "$G/etc/systemd/system/haproxy.service.d/mail-edge.conf"

conf_with examples/gateway.conf "$TMP/gw-open.conf" SMTP_ALLOWLIST_ENABLED=no \
  'SERVICES="smtp smtps submission imap imaps pop3 pop3s sieve"' \
  'HAPROXY_DENY_SRC_EXTRA="203.0.113.128/25 198.51.100.9"'
run_rc "gateway --render: после переключения MX, все сервисы" 0 \
  gateway/install.sh -c "$TMP/gw-open.conf" --render "$TMP/gw-open"
expect_no "haproxy: allowlist выключен" 'smtp-allow' "$TMP/gw-open/etc/haproxy/haproxy.cfg"
expect "haproxy: pop3 на 110" '^    bind 203\.0\.113\.10:110$' "$TMP/gw-open/etc/haproxy/haproxy.cfg"
expect "deny-src: дополнительная сеть" '^203\.0\.113\.128/25$' "$TMP/gw-open/etc/haproxy/deny-src.lst"
expect "deny-src: адрес без маски — /32" '^198\.51\.100\.9/32$' "$TMP/gw-open/etc/haproxy/deny-src.lst"

conf_with examples/gateway.conf "$TMP/gw-loop.conf" RELAY_HOSTNAME=mail.example.com
run_rc "gateway: RELAY_HOSTNAME = MAIL_HOSTNAME — ошибка" 1 \
  gateway/install.sh -c "$TMP/gw-loop.conf" --render "$TMP/x"
expect "gateway: объяснение про loops back to myself" 'loops back to myself'
conf_with examples/gateway.conf "$TMP/gw-badip.conf" GATEWAY_PUBLIC_IPV4=203.0.113.300
run_rc "gateway: некорректный адрес — ошибка" 1 gateway/install.sh -c "$TMP/gw-badip.conf" --render "$TMP/x"
expect "gateway: имя настройки в ошибке" "GATEWAY_PUBLIC_IPV4='203\.0\.113\.300'"
conf_with examples/gateway.conf "$TMP/gw-badsvc.conf" 'SERVICES="smtp pop2"'
run_rc "gateway: неизвестный сервис — ошибка" 1 gateway/install.sh -c "$TMP/gw-badsvc.conf" --render "$TMP/x"
conf_with examples/gateway.conf "$TMP/gw-badcidr.conf" 'HAPROXY_DENY_SRC_EXTRA="10.0.0.0/40"'
run_rc "gateway: некорректная сеть в списке — ошибка" 1 gateway/install.sh -c "$TMP/gw-badcidr.conf" --render "$TMP/x"
run_rc "gateway: нет файла настроек — ошибка" 1 gateway/install.sh -c "$TMP/nope.conf" --render "$TMP/x"
expect "gateway: подсказка про examples/" 'examples/'
run_rc "gateway: неизвестный аргумент — код 2" 2 gateway/install.sh --bogus
run_rc "gateway: -c без значения — код 2" 2 gateway/install.sh -c
run_rc "gateway --help" 0 gateway/install.sh --help
expect "gateway --help: --yes" '--yes'
expect "gateway --help: примеры" '^Примеры:'

# ------------------------------------------------------------------ relay
echo "== gateway/setup-relay.sh"
run_rc "setup-relay --dry-run" 0 gateway/setup-relay.sh -c examples/gateway.conf --dry-run
expect "setup-relay: заголовок плана" 'Postfix relay на порту 2525 \(от 100\.64\.0\.20\)'
if ! command -v postconf >/dev/null 2>&1; then
  expect "setup-relay: без postfix — список параметров" 'smtp_bind_address = 203\.0\.113\.10'
fi
run_rc "setup-relay: неизвестный аргумент — код 2" 2 gateway/setup-relay.sh --bogus

# ------------------------------------------------------------------ бэкенд: рендер и план
echo "== backend/install.sh"
B=$TMP/be
run_rc "backend --render (examples/backend.conf)" 0 backend/install.sh -c examples/backend.conf --render "$B"
if grep -rq '{{' "$B"; then t_fail "backend: остались {{...}}"; else t_ok "backend: все переменные подставлены"; fi
BN=$B/etc/mailcow-edge.nft
expect "nft бэкенда: PROXY-порты только со шлюза" 'iifname "wg0" ip saddr \$GATEWAY tcp dport \{ 10025, 10110, 10143, 10465, 10587, 10993, 10995, 14190 \} accept' "$BN"
expect "nft бэкенда: остальным — drop" 'iifname != "br-mailcow" tcp dport \{ 10025.* counter drop' "$BN"
expect "nft бэкенда: IPv6 на почтовые и веб-порты — drop" 'meta nfproto ipv6 iifname != "br-mailcow" tcp dport \{ 25, 80, 110, 143, 443, 465, 587, 993, 995, 4190, 10025' "$BN"
expect "nft бэкенда: tcp/25 наружу — только шлюз" 'tcp dport 25 ip daddr != \$GATEWAY_PUBLIC counter reject' "$BN"
expect "sysctl: ip_nonlocal_bind" '^net\.ipv4\.ip_nonlocal_bind = 1$' "$B/etc/sysctl.d/90-mailcow-nonlocal-bind.conf"
HOOK=$B/usr/local/sbin/mailcow-cert-reload.sh
expect "хук сертификата: каталог mailcow" '^cd "/opt/mailcow-dockerized"' "$HOOK"
if [ -x "$HOOK" ]; then t_ok "хук сертификата: исполняемый"; else t_fail "хук сертификата: не исполняемый"; fi

# Фейковый каталог mailcow для плана (--dry-run без root).
MC=$TMP/mailcow
mkdir -p "$MC/helper-scripts/docker-compose.override.yml.d/HAPROXY" "$MC/data/conf/dovecot" \
  "$MC/data/conf/postfix" "$MC/data/conf/nginx"
printf 'MAILCOW_HOSTNAME=mail.example.com\nSKIP_LETS_ENCRYPT=n\n' > "$MC/mailcow.conf"
printf 'services:\n  postfix-mailcow:\n    ports:\n      - "${SMTP_PORT_HAPROXY:-127.0.0.1:10025}:10025"\n' \
  > "$MC/helper-scripts/docker-compose.override.yml.d/HAPROXY/docker-compose.override.yml"
conf_with examples/backend.conf "$TMP/backend.conf" "MAILCOW_DIR=$MC"
run_rc "backend --dry-run (фейковый mailcow)" 0 backend/install.sh -c "$TMP/backend.conf" --dry-run
expect "план: SKIP_LETS_ENCRYPT=y" '^    \+SKIP_LETS_ENCRYPT=y$'
expect "план: PROXY-порт smtp на адресе оверлея" '^    \+SMTP_PORT_HAPROXY=100\.64\.0\.20:10025$'
expect "план: невключённый pop3 — на 127.0.0.1" '^    \+POP_PORT_HAPROXY=127\.0\.0\.1:10110$'
expect "план: override из helper-scripts" 'docker-compose\.override\.yml \(будет\)'
expect "план: Dovecot haproxy_trusted_networks" '^    \+haproxy_trusted_networks = 100\.64\.0\.10/32$'
expect "план: nginx set_real_ip_from" '^    \+set_real_ip_from 100\.64\.0\.10/32;$'
expect "план: relayhost через шлюз" '^    \+relayhost = \[100\.64\.0\.10\]:2525$'
expect "план: итог dry-run" 'dry-run: ничего не изменено \(файлов к изменению: [0-9]+\)'
if grep -q '^SKIP_LETS_ENCRYPT=n$' "$MC/mailcow.conf" && [ ! -e "$MC/docker-compose.override.yml" ]; then
  t_ok "backend --dry-run: файлы mailcow не изменены"
else
  t_fail "backend --dry-run изменил файлы mailcow"
fi
printf 'services: {}\n' > "$MC/docker-compose.override.yml"
run_rc "backend --dry-run: чужой override — предупреждение" 0 backend/install.sh -c "$TMP/backend.conf" --dry-run
expect "backend: просьба слить override вручную" 'Слейте его вручную'
run_rc "backend: неизвестный аргумент — код 2" 2 backend/install.sh --bogus

# ------------------------------------------------------------------ сертификат
echo "== backend/issue-cert.sh"
ACME=$TMP/acme
conf_with examples/backend.conf "$TMP/cert.conf" "ACME_HOME=$ACME"
run_rc "issue-cert --staging --dry-run" 0 backend/issue-cert.sh -c "$TMP/cert.conf" --staging --dry-run
expect "staging: выпуск через letsencrypt_test" '\[dry-run\] .*acme\.sh --home .* --issue --server letsencrypt_test --dns dns_xxx -d mail\.example\.com --keylength 2048 --force'
run_rc "issue-cert --production --dry-run" 0 backend/issue-cert.sh -c "$TMP/cert.conf" --production --dry-run
expect "production: CA по умолчанию" '--set-default-ca --server letsencrypt'
expect "production: выпуск" '--issue --server letsencrypt --dns dns_xxx'
expect "production: установка в mailcow" '--install-cert -d mail\.example\.com --key-file /opt/mailcow-dockerized/data/assets/ssl/key\.pem'
expect "production: cron" '--install-cronjob'
mkdir -p "$ACME/mail.example.com"
printf "Le_API='https://acme-v02.api.letsencrypt.org/directory'\n" > "$ACME/mail.example.com/mail.example.com.conf"
run_rc "staging поверх боевого — отказ" 1 backend/issue-cert.sh -c "$TMP/cert.conf" --staging --dry-run
run_rc "production: боевой уже есть — без выпуска" 0 backend/issue-cert.sh -c "$TMP/cert.conf" --production --dry-run
expect_no "production: --issue не вызывается" '--issue'
printf "Le_API='https://acme-staging-v02.api.letsencrypt.org/directory'\n" > "$ACME/mail.example.com/mail.example.com.conf"
run_rc "production после тестового" 0 backend/issue-cert.sh -c "$TMP/cert.conf" --production --dry-run
expect "production после тестового: --force" '--issue --server letsencrypt .* --force'
conf_with examples/backend.conf "$TMP/cert-bad.conf" ACME_DNS_API=xxx
run_rc "issue-cert: ACME_DNS_API не dns_* — ошибка" 1 backend/issue-cert.sh -c "$TMP/cert-bad.conf" --staging --dry-run
run_rc "issue-cert: без режима — код 2" 2 backend/issue-cert.sh -c "$TMP/cert.conf"

# ------------------------------------------------------------------ tools
echo "== tools"
run_rc "check-tls --help" 0 tools/check-tls.sh --help
run_rc "check-tls без HOST — код 64" 64 tools/check-tls.sh
run_rc "check-tls: некорректный порт — код 64" 64 tools/check-tls.sh mail.example.com 25x
run_rc "check-tls: закрытый порт — FAIL" 1 tools/check-tls.sh 127.0.0.1 1
expect "check-tls: строка FAIL" '^1 +FAIL'
expect "check-tls: итог" '^итого: OK 0, WARN 0, FAIL 1$'
run_rc "check-relay --help" 0 tools/check-relay.sh --help
run_rc "check-relay без HOST — код 64" 64 tools/check-relay.sh

# Фейковый SMTP-сервер: ответ на RCPT задаёт сценарий.
smtp_case() {   # smtp_case NAME RC MODE REGEX
  local name=$1 want=$2 mode=$3 re=$4 port=""
  rm -f "$TMP/smtp.port"
  python3 "$ROOT/tests/fake_smtp.py" "$TMP/smtp.port" "$mode" &
  local pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$TMP/smtp.port" ] && break
    sleep 0.1
  done
  port=$(cat "$TMP/smtp.port" 2>/dev/null)
  run_rc "$name" "$want" env PORT="$port" HELO=test.example tools/check-relay.sh 127.0.0.1
  expect "$name: вывод" "$re"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
if command -v python3 >/dev/null 2>&1; then
  smtp_case "check-relay: relay запрещён — OK" 0 denied '^OK +relay запрещён \(554 Relay access denied\)'
  smtp_case "check-relay: open relay — FAIL" 2 open '^FAIL +OPEN RELAY'
  smtp_case "check-relay: отказ не из-за relay — WARN" 1 unknown '^WARN +RCPT отклонён \(550\)'
  smtp_case "check-relay: сервер не принял соединение — WARN" 1 busy '^WARN +сервер не принял соединение \(554\)'
else
  echo "skip  check-relay против фейкового сервера: нет python3"
fi

# ------------------------------------------------------------------ версии
echo "== версии"
for s in gateway/install.sh gateway/setup-relay.sh backend/install.sh backend/issue-cert.sh \
  tools/check-tls.sh tools/check-relay.sh; do
  run_rc "$s --version" 0 "$s" --version
  expect "$s --version = CHANGELOG ($VERSION)" "^mailcow-edge-gateway $VERSION\$"
done

echo
echo "итого: пройдено $PASS, ошибок $FAILED"
[ "$FAILED" = 0 ]
