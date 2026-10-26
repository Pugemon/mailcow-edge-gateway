#!/usr/bin/env bash
# Postfix на шлюзе как relay исходящей почты mailcow.
# Принимает почту только от бэкенда (его адрес в оверлее) на порту RELAY_PORT и отправляет её
# в интернет с публичного адреса шлюза (PTR = MAIL_HOSTNAME, адрес входит в SPF).
# Порт 25 шлюза остаётся за HAProxy: стандартный smtpd на 25 выключается.
# Снаружи RELAY_PORT закрыт таблицей nftables inet mail_edge (gateway/install.sh).
#
# Нужен дистрибутив с apt и debconf. Повторный запуск безопасен: postfix перезапускается,
# только если конфигурация изменилась.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SELF_DIR")
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"

usage() {
  cat <<EOF
Использование: gateway/setup-relay.sh [-c FILE] [--dry-run]

  -c, --config FILE  файл настроек (по умолчанию: gateway.conf в корне репозитория)
  --dry-run          показать, какие параметры Postfix изменятся; ничего не менять
EOF
}

CONF=$REPO_DIR/gateway.conf
while [ $# -gt 0 ]; do
  case $1 in
    -c|--config) CONF=${2:?не указан файл настроек}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
done

load_conf "$CONF"
require_vars GATEWAY_PUBLIC_IPV4 BACKEND_OVERLAY_IP MAIL_HOSTNAME RELAY_HOSTNAME RELAY_PORT
set_default RELAY_INET_PROTOCOLS ipv4
set_default RELAY_MESSAGE_SIZE_LIMIT 104857600
check is_ipv4 GATEWAY_PUBLIC_IPV4
check is_ipv4 BACKEND_OVERLAY_IP
check is_fqdn MAIL_HOSTNAME
check is_fqdn RELAY_HOSTNAME
check is_port RELAY_PORT
case $RELAY_INET_PROTOCOLS in ipv4|all|ipv6|"ipv4, ipv6") ;; *) die "некорректное значение RELAY_INET_PROTOCOLS='$RELAY_INET_PROTOCOLS'" ;; esac
[[ $RELAY_MESSAGE_SIZE_LIMIT =~ ^[0-9]+$ ]] || die "некорректное значение RELAY_MESSAGE_SIZE_LIMIT"
[ "$RELAY_PORT" != 25 ] || die "RELAY_PORT не может быть 25: порт 25 занят HAProxy"

# myhostname relay обязан отличаться от myhostname mailcow: иначе mailcow увидит своё имя
# в приветствии relay и отбросит письма как "loops back to myself".
[ "$RELAY_HOSTNAME" != "$MAIL_HOSTNAME" ] ||
  die "RELAY_HOSTNAME должен отличаться от MAIL_HOSTNAME (иначе 'loops back to myself')"

# Кэш TLS-сессий: btree, если Postfix его поддерживает (в новых сборках может остаться только lmdb).
scache=""
if have postconf; then
  if postconf -m | grep -qx btree; then
    scache='btree:${data_directory}/smtp_scache'
  elif postconf -m | grep -qx lmdb; then
    scache='lmdb:${data_directory}/smtp_scache'
  fi
else
  scache='btree:${data_directory}/smtp_scache'
fi

# Параметры main.cf. Значения с $ — в одинарных кавычках: Postfix раскрывает их сам.
SETTINGS=(
  "compatibility_level = 2"
  "myhostname = $RELAY_HOSTNAME"
  "mydomain = ${RELAY_HOSTNAME#*.}"
  'myorigin = $myhostname'
  'smtpd_banner = $myhostname ESMTP'
  "biff = no"
  "append_dot_mydomain = no"
  "inet_interfaces = all"
  # У большинства VPS нет PTR для IPv6 — отправка по IPv6 даёт отказы у крупных почтовиков.
  "inet_protocols = $RELAY_INET_PROTOCOLS"
  # Локальная доставка выключена: relay ничего не принимает для себя.
  "mydestination ="
  "relay_domains ="
  "local_recipient_maps ="
  "local_transport = error:local delivery disabled"
  "alias_maps ="
  "alias_database ="
  # Принимаем только от бэкенда (адрес контейнеров mailcow после NAT Docker — адрес бэкенда в оверлее).
  "mynetworks = 127.0.0.0/8 $BACKEND_OVERLAY_IP/32"
  "smtpd_client_restrictions = permit_mynetworks, reject"
  "smtpd_relay_restrictions = permit_mynetworks, reject"
  "smtpd_recipient_restrictions = permit_mynetworks, reject"
  # Между бэкендом и шлюзом трафик идёт внутри шифрованного оверлея.
  "smtpd_tls_security_level = none"
  # Наружу: с публичного адреса шлюза, HELO = публичное имя mailcow (совпадает с PTR).
  "smtp_bind_address = $GATEWAY_PUBLIC_IPV4"
  "smtp_helo_name = $MAIL_HOSTNAME"
  "smtp_tls_security_level = may"
  "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
  "smtp_tls_loglevel = 1"
  "smtp_tls_session_cache_database = $scache"
  # Не перекодировать 8bit -> quoted-printable: иначе ломается подпись DKIM, поставленная mailcow.
  "disable_mime_output_conversion = yes"
  "message_size_limit = $RELAY_MESSAGE_SIZE_LIMIT"
  "mailbox_size_limit = 0"
)

MASTER_ENTRY="$RELAY_PORT/inet=$RELAY_PORT inet n - y - - smtpd"
MASTER_SYSLOG="$RELAY_PORT/inet/syslog_name=postfix/from-mailcow"

postfix_state() {
  postconf -n 2>/dev/null
  postconf -M 2>/dev/null
  postconf -P 2>/dev/null
}

log "Postfix relay на порту $RELAY_PORT (от $BACKEND_OVERLAY_IP)"

if [ "$DRY_RUN" = 1 ]; then
  if ! have postconf; then
    info "postfix не установлен — будет установлен и настроен с параметрами:"
    for kv in "${SETTINGS[@]}"; do info "  $kv"; done
    info "  master.cf: $MASTER_ENTRY"
    exit 0
  fi
  for kv in "${SETTINGS[@]}"; do
    k=${kv%% =*}
    want=${kv#* = }
    [ "$want" != "$kv" ] || want=""
    cur=$(postconf -h "$k" 2>/dev/null || true)
    if [ "$cur" != "$want" ]; then
      info "$k: '$cur' -> '$want'"
    fi
  done
  if [ -n "$(postconf -M smtp/inet 2>/dev/null)" ]; then
    info "master.cf: smtp/inet (порт 25) будет закомментирован"
  fi
  if [ "$(postconf -M "$RELAY_PORT/inet" 2>/dev/null | tr -s ' \t' ' ')" != "${MASTER_ENTRY#*=}" ]; then
    info "master.cf: будет добавлено '$MASTER_ENTRY'"
  fi
  exit 0
fi

need_root

if ! dpkg -s postfix >/dev/null 2>&1; then
  have apt-get || die "postfix не установлен, а apt-get нет — установите postfix вручную"
  echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
  # До установки postconf не было — кэш TLS-сессий выбираем заново.
  exec "$0" -c "$CONF"
fi
[ -f /etc/postfix/master.cf ] || cp /usr/share/postfix/master.cf.dist /etc/postfix/master.cf
[ -f /etc/postfix/main.cf ] || touch /etc/postfix/main.cf

before=$(postfix_state)

postconf -e "${SETTINGS[@]}"
if [ -z "$scache" ]; then
  postconf -X smtp_tls_session_cache_database
fi

# Стандартный smtpd на 25 выключен — relay слушает только RELAY_PORT.
if [ -n "$(postconf -M smtp/inet 2>/dev/null)" ]; then
  postconf -M# smtp/inet
fi
postconf -M "$MASTER_ENTRY"
postconf -P "$MASTER_SYSLOG"

postfix check
systemctl enable postfix >/dev/null 2>&1
if [ "$before" != "$(postfix_state)" ] || ! systemctl is-active --quiet postfix; then
  info "конфигурация изменилась — перезапуск postfix"
  systemctl restart postfix
  sleep 1
else
  info "конфигурация postfix без изменений"
fi

ss -ltn | grep -Eq ":$RELAY_PORT\b" || die "postfix не слушает порт $RELAY_PORT"
postconf -n | grep -E '^(myhostname|smtp_helo_name|smtp_bind_address|mynetworks|inet_protocols) ' | sed 's/^/    /'
