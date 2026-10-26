#!/usr/bin/env bash
# Установка шлюза (VPS): HAProxy с PROXY protocol v2 к mailcow, таблица nftables inet mail_edge
# (mail-edge.service) и relay Postfix для исходящей почты (gateway/setup-relay.sh).
#
# Порядок: файлы готовятся во временном каталоге, проверяются (haproxy -c, nft -c), показывается
# diff с установленными версиями, и только потом устанавливаются. Повторный запуск с теми же
# настройками ничего не меняет. Предыдущие версии файлов — в /var/backups/mailcow-edge-gateway/.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SELF_DIR")
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"

usage() {
  cat <<EOF
Использование: gateway/install.sh [-c FILE] [--dry-run] [--render DIR] [--skip-relay] [--skip-packages]

  -c, --config FILE  файл настроек (по умолчанию: gateway.conf в корне репозитория)
  --dry-run          подготовить файлы, проверить и показать diff; ничего не менять
  --render DIR       только записать готовые файлы в DIR (root не нужен, можно на рабочей машине)
  --skip-relay       не настраивать Postfix relay
  --skip-packages    не устанавливать пакеты haproxy и nftables
EOF
}

CONF=$REPO_DIR/gateway.conf
RENDER_DIR=""
SKIP_RELAY=0
SKIP_PACKAGES=0
while [ $# -gt 0 ]; do
  case $1 in
    -c|--config) CONF=${2:?не указан файл настроек}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --render) RENDER_DIR=${2:?не указан каталог}; shift 2 ;;
    --skip-relay) SKIP_RELAY=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
done

# ---------------------------------------------------------------- настройки
load_conf "$CONF"
require_vars GATEWAY_PUBLIC_IPV4 GATEWAY_OVERLAY_IP BACKEND_OVERLAY_IP OVERLAY_IFACE \
  MAIL_HOSTNAME RELAY_HOSTNAME RELAY_PORT SERVICES
set_default OVERLAY_SERVICE ""
set_default SMTP_ALLOWLIST_ENABLED yes
set_default SMTP_ALLOWLIST ""
set_default HAPROXY_DENY_SRC_EXTRA ""
set_default HAPROXY_MAXCONN 4000
set_default HAPROXY_TIMEOUT_CONNECT 10s
set_default HAPROXY_TIMEOUT 10m
set_default HAPROXY_TIMEOUT_IMAP 35m

check is_ipv4 GATEWAY_PUBLIC_IPV4
check is_ipv4 GATEWAY_OVERLAY_IP
check is_ipv4 BACKEND_OVERLAY_IP
check is_ifname OVERLAY_IFACE
check is_fqdn MAIL_HOSTNAME
check is_fqdn RELAY_HOSTNAME
check is_port RELAY_PORT
check is_yesno SMTP_ALLOWLIST_ENABLED
validate_services
[[ $HAPROXY_MAXCONN =~ ^[0-9]+$ ]] || die "некорректное значение HAPROXY_MAXCONN='$HAPROXY_MAXCONN'"
timeout_re='^[0-9]+(us|ms|s|m|h|d)?$'
for v in HAPROXY_TIMEOUT_CONNECT HAPROXY_TIMEOUT HAPROXY_TIMEOUT_IMAP; do
  [[ ${!v} =~ $timeout_re ]] || die "некорректное значение $v='${!v}'"
done
[ "$RELAY_HOSTNAME" != "$MAIL_HOSTNAME" ] ||
  die "RELAY_HOSTNAME должен отличаться от MAIL_HOSTNAME: иначе mailcow отбросит письма с relay как 'loops back to myself'"

# Адрес в списке: a.b.c.d или a.b.c.d/nn; без маски — /32.
norm_cidr() {
  local a=$1
  case $a in */*) ;; *) a=$a/32 ;; esac
  is_cidr4 "$a" || die "некорректный адрес в списке: '$1'"
  printf '%s\n' "$a"
}

# ---------------------------------------------------------------- рендер
# Блоки listen для включённых сервисов (в фиксированном порядке, независимо от порядка в SERVICES).
build_listeners() {
  local s pub back
  for s in $ALL_SERVICES; do
    svc_enabled "$s" || continue
    pub=$(svc_public_port "$s")
    back=$(svc_proxy_port "$s")
    printf '\nlisten %s\n' "$s"
    printf '    bind %s:%s\n' "$GATEWAY_PUBLIC_IPV4" "$pub"
    case $s in
      imap|imaps)
        printf '    timeout client %s\n' "$HAPROXY_TIMEOUT_IMAP"
        printf '    timeout server %s\n' "$HAPROXY_TIMEOUT_IMAP"
        ;;
    esac
    printf '    tcp-request connection reject if { src -f /etc/haproxy/deny-src.lst }\n'
    if [ "$s" = smtp ] && [ "$SMTP_ALLOWLIST_ENABLED" = yes ]; then
      printf '    # До переключения MX приём на 25 — только с адресов из smtp-allow.lst, чтобы почта\n'
      printf '    # не оседала в новом сервере раньше времени. При переключении: SMTP_ALLOWLIST_ENABLED=no\n'
      printf '    # в gateway.conf и повторный запуск gateway/install.sh.\n'
      printf '    tcp-request connection reject if !{ src -f /etc/haproxy/smtp-allow.lst }\n'
    fi
    printf '    server mailcow %s:%s send-proxy-v2\n' "$BACKEND_OVERLAY_IP" "$back"
  done
}

LISTENERS=$(build_listeners)
PROXY_PORTS=$(all_proxy_ports)
export LISTENERS PROXY_PORTS

make_stage
OUT=${RENDER_DIR:-$STAGE/root}
mkdir -p "$OUT"

render_template "$SELF_DIR/templates/haproxy.cfg.tmpl" "$OUT/etc/haproxy/haproxy.cfg"
render_template "$SELF_DIR/templates/mail-edge.nft.tmpl" "$OUT/etc/mail-edge.nft"
render_template "$SELF_DIR/templates/mail-edge.service" "$OUT/etc/systemd/system/mail-edge.service"
render_template "$SELF_DIR/templates/haproxy-mail-edge.conf.tmpl" \
  "$OUT/etc/systemd/system/haproxy.service.d/mail-edge.conf"

{
  cat "$SELF_DIR/templates/deny-src.lst"
  for a in $HAPROXY_DENY_SRC_EXTRA; do norm_cidr "$a"; done
} > "$OUT/etc/haproxy/deny-src.lst"

# Собственный публичный адрес шлюза — всегда в списке: проверки с самого шлюза.
{
  printf '%s/32\n' "$GATEWAY_PUBLIC_IPV4"
  for a in $SMTP_ALLOWLIST; do norm_cidr "$a"; done
} | awk '!seen[$0]++' > "$OUT/etc/haproxy/smtp-allow.lst"

FILES="/etc/haproxy/haproxy.cfg /etc/haproxy/deny-src.lst /etc/haproxy/smtp-allow.lst
/etc/mail-edge.nft /etc/systemd/system/mail-edge.service /etc/systemd/system/haproxy.service.d/mail-edge.conf"

if [ -n "$RENDER_DIR" ]; then
  log "Файлы записаны в $RENDER_DIR"
  for f in $FILES; do info "$RENDER_DIR$f"; done
  exit 0
fi

if [ "$DRY_RUN" != 1 ]; then
  need_root
fi

# ---------------------------------------------------------------- пакеты
if [ "$SKIP_PACKAGES" != 1 ]; then
  missing=""
  have haproxy || missing="$missing haproxy"
  have nft || missing="$missing nftables"
  if [ -n "$missing" ] && [ "$DRY_RUN" = 1 ]; then
    log "Пакеты"
    info "будут установлены:$missing"
  elif [ -n "$missing" ]; then
    log "Пакеты:$missing"
    have apt-get || die "нет apt-get: установите$missing вручную и запустите с --skip-packages"
    apt-get update
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
  fi
fi

# ---------------------------------------------------------------- проверка синтаксиса
log "Проверка синтаксиса"
if have haproxy; then
  # Списки в haproxy.cfg указаны абсолютными путями — для проверки подставляем подготовленные копии.
  sed "s#/etc/haproxy/#$OUT/etc/haproxy/#g" "$OUT/etc/haproxy/haproxy.cfg" > "$STAGE/haproxy-check.cfg"
  haproxy -c -f "$STAGE/haproxy-check.cfg" >/dev/null ||
    die "haproxy -c: ошибка в подготовленном haproxy.cfg (подробности выше)"
  info "haproxy -c: OK"
else
  info "haproxy не установлен — проверка haproxy -c пропущена"
fi
if have nft && is_root && id haproxy >/dev/null 2>&1; then
  nft -c -f "$OUT/etc/mail-edge.nft" || die "nft -c: ошибка в подготовленном mail-edge.nft"
  info "nft -c: OK"
else
  info "nft -c пропущен (нужны nft, root и пользователь haproxy)"
fi

# ---------------------------------------------------------------- установка
log "Файлы шлюза"
apply_file "$OUT/etc/mail-edge.nft" /etc/mail-edge.nft
nft_changed=$APPLIED
apply_file "$OUT/etc/systemd/system/mail-edge.service" /etc/systemd/system/mail-edge.service
units_changed=$APPLIED
apply_file "$OUT/etc/systemd/system/haproxy.service.d/mail-edge.conf" \
  /etc/systemd/system/haproxy.service.d/mail-edge.conf
units_changed=$((units_changed | APPLIED))
haproxy_changed=0
for f in /etc/haproxy/haproxy.cfg /etc/haproxy/deny-src.lst /etc/haproxy/smtp-allow.lst; do
  apply_file "$OUT$f" "$f"
  haproxy_changed=$((haproxy_changed | APPLIED))
done

if [ "$DRY_RUN" = 1 ]; then
  if [ "$SKIP_RELAY" != 1 ]; then
    "$SELF_DIR/setup-relay.sh" -c "$CONF" --dry-run
  fi
  log "dry-run: ничего не изменено (файлов к изменению: $CHANGED)"
  exit 0
fi

if [ "$units_changed" = 1 ]; then
  systemctl daemon-reload
fi

# Сначала таблица nftables (до HAProxy): защита PROXY-портов должна действовать раньше, чем
# появится первое соединение к бэкенду.
systemctl enable mail-edge.service >/dev/null 2>&1
if [ "$nft_changed" = 1 ] || ! systemctl is-active --quiet mail-edge.service; then
  log "Загрузка таблицы nftables inet mail_edge"
  systemctl restart mail-edge.service
fi
nft list table inet mail_edge >/dev/null || die "таблица inet mail_edge не загружена"

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || die "haproxy -c: ошибка в /etc/haproxy/haproxy.cfg"
systemctl enable haproxy.service >/dev/null 2>&1
if [ "$haproxy_changed" = 1 ] || [ "$units_changed" = 1 ] || ! systemctl is-active --quiet haproxy.service; then
  log "Перезагрузка HAProxy"
  systemctl reload-or-restart haproxy.service
fi

if [ "$SKIP_RELAY" != 1 ]; then
  "$SELF_DIR/setup-relay.sh" -c "$CONF"
fi

log "Готово. Проверки:"
info "ss -ltnp | grep haproxy          # порты на $GATEWAY_PUBLIC_IPV4"
info "nft list table inet mail_edge    # счётчики drop/reject"
info "sudo -u nobody bash -c 'exec 3<>/dev/tcp/$BACKEND_OVERLAY_IP/10025'   # должно быть: Connection refused"
info "tools/check-tls.sh $MAIL_HOSTNAME   # с адреса из SMTP_ALLOWLIST (для порта 25)"
info "tools/check-relay.sh $MAIL_HOSTNAME # ожидается Relay access denied"
