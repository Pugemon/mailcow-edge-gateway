#!/usr/bin/env bash
# Подготовка сервера mailcow (бэкенда) к работе за шлюзом:
#   - таблица nftables inet mailcow_edge (+ mailcow-edge.service): к PROXY-портам — только шлюз,
#     IPv6 на почтовые порты — drop, из контейнеров mailcow наружу tcp/25 — только на шлюз;
#   - net.ipv4.ip_nonlocal_bind = 1 (порты публикуются на адресе оверлея);
#   - mailcow.conf: SKIP_LETS_ENCRYPT и *_PORT_HAPROXY; docker-compose.override.yml с портами
#     haproxy-listeners из helper-scripts mailcow;
#   - Dovecot: haproxy_trusted_networks; nginx: set_real_ip_from; Postfix: relayhost через шлюз;
#   - /etc/docker/daemon.json: "userland-proxy": false;
#   - хук перезагрузки сертификата для acme.sh: /usr/local/sbin/mailcow-cert-reload.sh.
#
# Docker и контейнеры mailcow скрипт НЕ перезапускает — это отдельный шаг (см. README).
# Повторный запуск с теми же настройками ничего не меняет. Предыдущие версии файлов —
# в /var/backups/mailcow-edge-gateway/.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SELF_DIR")
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"

usage() {
  cat <<EOF
Использование: backend/install.sh [-c FILE] [--dry-run] [--render DIR]

  -c, --config FILE  файл настроек (по умолчанию: backend.conf в корне репозитория)
  --dry-run          показать diff всех изменений; ничего не менять
  --render DIR       только записать системные файлы (nftables, systemd, sysctl, хук) в DIR
EOF
}

CONF=$REPO_DIR/backend.conf
RENDER_DIR=""
while [ $# -gt 0 ]; do
  case $1 in
    -c|--config) CONF=${2:?не указан файл настроек}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --render) RENDER_DIR=${2:?не указан каталог}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
done

# ---------------------------------------------------------------- настройки
load_conf "$CONF"
require_vars MAILCOW_DIR BACKEND_OVERLAY_IP GATEWAY_OVERLAY_IP GATEWAY_PUBLIC_IPV4 \
  OVERLAY_IFACE SERVICES RELAY_PORT
set_default MAILCOW_BRIDGE br-mailcow
set_default MAILCOW_HTTP_PORT 80
set_default MAILCOW_HTTPS_PORT 443
set_default SKIP_LETS_ENCRYPT y
set_default CONFIGURE_RELAYHOST yes

check is_ipv4 BACKEND_OVERLAY_IP
check is_ipv4 GATEWAY_OVERLAY_IP
check is_ipv4 GATEWAY_PUBLIC_IPV4
check is_ifname OVERLAY_IFACE
check is_ifname MAILCOW_BRIDGE
check is_port RELAY_PORT
check is_port MAILCOW_HTTP_PORT
check is_port MAILCOW_HTTPS_PORT
check is_yesno CONFIGURE_RELAYHOST
case $SKIP_LETS_ENCRYPT in y|n) ;; *) die "SKIP_LETS_ENCRYPT: допустимо y или n" ;; esac
validate_services

PROXY_PORTS=$(all_proxy_ports)
# shellcheck disable=SC2046
IPV6_DROP_PORTS=$(port_list 25 110 143 465 587 993 995 4190 "$MAILCOW_HTTP_PORT" "$MAILCOW_HTTPS_PORT" \
  $(for s in $ALL_SERVICES; do svc_proxy_port "$s"; done))
export PROXY_PORTS IPV6_DROP_PORTS

MC=$MAILCOW_DIR
NGINX_REAL_IP_FILE=site.real-ip-gateway.custom

# ---------------------------------------------------------------- системные файлы из шаблонов
make_stage
OUT=${RENDER_DIR:-$STAGE/root}
mkdir -p "$OUT"
render_template "$SELF_DIR/templates/mailcow-edge.nft.tmpl" "$OUT/etc/mailcow-edge.nft"
render_template "$SELF_DIR/templates/mailcow-edge.service" "$OUT/etc/systemd/system/mailcow-edge.service"
render_template "$SELF_DIR/templates/90-mailcow-nonlocal-bind.conf" "$OUT/etc/sysctl.d/90-mailcow-nonlocal-bind.conf"
render_template "$SELF_DIR/templates/mailcow-cert-reload.sh.tmpl" "$OUT/usr/local/sbin/mailcow-cert-reload.sh"
chmod 755 "$OUT/usr/local/sbin/mailcow-cert-reload.sh"

if [ -n "$RENDER_DIR" ]; then
  log "Файлы записаны в $RENDER_DIR"
  (cd "$RENDER_DIR" && find . -type f | sed 's#^\.#    #')
  exit 0
fi

if [ "$DRY_RUN" != 1 ]; then
  need_root
fi

[ -f "$MC/mailcow.conf" ] || die "не найден $MC/mailcow.conf — укажите MAILCOW_DIR установленного mailcow"
HAPROXY_OVERRIDE=$MC/helper-scripts/docker-compose.override.yml.d/HAPROXY/docker-compose.override.yml
[ -f "$HAPROXY_OVERRIDE" ] ||
  die "нет $HAPROXY_OVERRIDE — обновите mailcow до версии с haproxy-listeners (PROXY protocol)"

# docker-compose.override.yml: если файл уже есть и не содержит портов haproxy-listeners,
# автоматически его не трогаем — YAML нужно слить вручную. Проверяем до любых изменений.
OVERRIDE=$MC/docker-compose.override.yml
override_action=keep
if [ ! -f "$OVERRIDE" ]; then
  override_action=copy
elif ! grep -q '_PORT_HAPROXY' "$OVERRIDE"; then
  msg="$OVERRIDE уже существует и не содержит портов haproxy-listeners.
    Слейте его вручную с $HAPROXY_OVERRIDE
    (секции ports у postfix-mailcow и dovecot-mailcow) и запустите скрипт снова.
    Проверка после слияния: cd $MC && docker compose config | grep -A3 'host_ip: $BACKEND_OVERLAY_IP'"
  if [ "$DRY_RUN" = 1 ]; then
    warn "$msg"
  else
    die "$msg"
  fi
fi

log "Проверка синтаксиса"
if have nft && is_root; then
  nft -c -f "$OUT/etc/mailcow-edge.nft" || die "nft -c: ошибка в подготовленном mailcow-edge.nft"
  info "nft -c: OK"
else
  info "nft -c пропущен (нужны nft и root)"
fi

# ---------------------------------------------------------------- система
log "Системные файлы"
apply_file "$OUT/etc/sysctl.d/90-mailcow-nonlocal-bind.conf" /etc/sysctl.d/90-mailcow-nonlocal-bind.conf
sysctl_changed=$APPLIED
apply_file "$OUT/etc/mailcow-edge.nft" /etc/mailcow-edge.nft
nft_changed=$APPLIED
apply_file "$OUT/etc/systemd/system/mailcow-edge.service" /etc/systemd/system/mailcow-edge.service
unit_changed=$APPLIED
apply_file "$OUT/usr/local/sbin/mailcow-cert-reload.sh" /usr/local/sbin/mailcow-cert-reload.sh 0755

# Без docker-proxy: иначе IPv6-соединения к опубликованным портам приходят в контейнеры
# с 172.22.1.1 (входит в mynetworks mailcow) — open relay.
log "Docker: userland-proxy = false"
f=$(stage_copy /etc/docker/daemon.json)
if have python3; then
  python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as fh:
    text = fh.read()
d = json.loads(text) if text.strip() else {}
if d.get("userland-proxy") is not False:
    d["userland-proxy"] = False
    with open(p, "w") as fh:
        json.dump(d, fh, indent=2)
        fh.write("\n")
PY
elif have jq; then
  if [ -s "$f" ]; then
    if [ "$(jq '."userland-proxy"' "$f")" != false ]; then
      jq '."userland-proxy" = false' "$f" > "$f.new" && mv "$f.new" "$f"
    fi
  else
    printf '{\n  "userland-proxy": false\n}\n' > "$f"
  fi
elif [ ! -s "$f" ]; then
  printf '{\n  "userland-proxy": false\n}\n' > "$f"
else
  die "для правки /etc/docker/daemon.json нужен python3 или jq (или добавьте \"userland-proxy\": false вручную)"
fi
apply_file "$f" /etc/docker/daemon.json
docker_changed=$APPLIED

# ---------------------------------------------------------------- mailcow
log "mailcow.conf"
f=$(stage_copy "$MC/mailcow.conf")
# Сертификат выпускает acme.sh через DNS-01 (backend/issue-cert.sh); встроенный ACME mailcow
# (HTTP-01) за reverse proxy на шлюзе не работает.
set_kv "$f" SKIP_LETS_ENCRYPT "$SKIP_LETS_ENCRYPT"
if ! grep -q '^[A-Z_]*_PORT_HAPROXY=' "$f"; then
  ensure_newline "$f"
  cat >> "$f" <<EOF

# --- PROXY protocol: HAProxy на шлюзе через оверлейную сеть (mailcow-edge-gateway) ---
# Доступ к этим портам ограничен таблицей nftables inet mailcow_edge (только $GATEWAY_OVERLAY_IP).
# Порты сервисов, которые не публикуются через шлюз, остаются на 127.0.0.1.
EOF
fi
for s in $ALL_SERVICES; do
  if svc_enabled "$s"; then addr=$BACKEND_OVERLAY_IP; else addr=127.0.0.1; fi
  set_kv "$f" "$(svc_mailcow_var "$s")" "$addr:$(svc_proxy_port "$s")"
done
apply_file "$f" "$MC/mailcow.conf"
compose_changed=$APPLIED

log "docker-compose.override.yml"
if [ "$override_action" = copy ]; then
  apply_file "$HAPROXY_OVERRIDE" "$OVERRIDE"
  compose_changed=$((compose_changed | APPLIED))
else
  info "без изменений: $OVERRIDE"
fi

log "Dovecot: haproxy_trusted_networks"
f=$(stage_copy "$MC/data/conf/dovecot/extra.conf")
set_param "$f" haproxy_trusted_networks "$GATEWAY_OVERLAY_IP/32" \
"# PROXY-заголовок Dovecot принимает только от HAProxy на шлюзе (mailcow-edge-gateway).
# В login_trusted_networks шлюз НЕ добавлять: это разрешило бы вход открытым паролем без TLS."
apply_file "$f" "$MC/data/conf/dovecot/extra.conf"
restart_needed=$APPLIED

# nginx: real_ip_header/real_ip_recursive обычно уже есть в конфигурации mailcow; второй
# real_ip_header в том же блоке — ошибка "is duplicate", и nginx не стартует. Добавляем его,
# только если в работающем nginx (без учёта нашего файла) его точно нет.
log "nginx: set_real_ip_from для reverse proxy на шлюзе"
nginx_real_ip_header=unknown
if have docker; then
  dump=$(cd "$MC" && docker compose exec -T nginx-mailcow nginx -T 2>/dev/null) || dump=""
  if [ -n "$dump" ]; then
    if printf '%s\n' "$dump" | awk -v own="$NGINX_REAL_IP_FILE" '
        /^# configuration file / { skip = (index($0, own) > 0); next }
        !skip && /^[[:space:]]*real_ip_header[[:space:]]/ { found = 1 }
        END { exit found ? 0 : 1 }'; then
      nginx_real_ip_header=present
    else
      nginx_real_ip_header=absent
    fi
  fi
fi
nginx_file=$MC/data/conf/nginx/$NGINX_REAL_IP_FILE
f=$STAGE/edit-nginx-real-ip
{
  echo "# Реальный IP клиентов веб-интерфейса за reverse proxy на шлюзе (mailcow-edge-gateway)."
  echo "set_real_ip_from $GATEWAY_OVERLAY_IP/32;"
  case $nginx_real_ip_header in
    absent)
      echo "real_ip_header X-Forwarded-For;"
      echo "real_ip_recursive on;"
      ;;
    unknown)
      # nginx не запущен — сохраняем то, что было в нашем файле раньше.
      if [ -f "$nginx_file" ]; then grep -E '^real_ip_(header|recursive) ' "$nginx_file" || true; fi
      ;;
  esac
} > "$f"
if [ "$nginx_real_ip_header" = unknown ]; then
  warn "nginx-mailcow не запущен: после старта проверьте 'docker compose exec nginx-mailcow nginx -T | grep real_ip_header'.
    Если строки нет — запустите скрипт ещё раз (он добавит real_ip_header в $NGINX_REAL_IP_FILE)."
fi
apply_file "$f" "$nginx_file"
restart_needed=$((restart_needed | APPLIED))

if [ "$CONFIGURE_RELAYHOST" = yes ]; then
  log "Postfix: relayhost через шлюз"
  f=$(stage_copy "$MC/data/conf/postfix/extra.cf")
  set_param "$f" relayhost "[$GATEWAY_OVERLAY_IP]:$RELAY_PORT" \
"# Вся исходящая почта — через relay Postfix на шлюзе: публичный адрес шлюза имеет PTR и входит в SPF."
  apply_file "$f" "$MC/data/conf/postfix/extra.cf"
  restart_needed=$((restart_needed | APPLIED))
fi

# ---------------------------------------------------------------- применение
if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: ничего не изменено (файлов к изменению: $CHANGED)"
  exit 0
fi

if [ "$sysctl_changed" = 1 ]; then
  sysctl -q -p /etc/sysctl.d/90-mailcow-nonlocal-bind.conf
fi
if [ "$unit_changed" = 1 ]; then
  systemctl daemon-reload
fi
systemctl enable mailcow-edge.service >/dev/null 2>&1
if [ "$nft_changed" = 1 ] || ! systemctl is-active --quiet mailcow-edge.service; then
  log "Загрузка таблицы nftables inet mailcow_edge"
  systemctl restart mailcow-edge.service
fi
nft list table inet mailcow_edge >/dev/null || die "таблица inet mailcow_edge не загружена"

log "Дальше (вручную)"
step=1
if [ "$docker_changed" = 1 ]; then
  info "$step. systemctl restart docker      # применить userland-proxy=false (перезапустит все контейнеры)"
  step=$((step + 1))
fi
if [ "$compose_changed" = 1 ] || [ "$docker_changed" = 1 ]; then
  info "$step. cd $MC && docker compose up -d   # опубликовать PROXY-порты на $BACKEND_OVERLAY_IP"
  step=$((step + 1))
elif [ "$restart_needed" = 1 ]; then
  info "$step. cd $MC && docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow"
  step=$((step + 1))
fi
info "$step. Whitelist Fail2ban mailcow: добавьте $GATEWAY_OVERLAY_IP/32 (README, шаг 1)"
step=$((step + 1))
info "$step. Сертификат: backend/issue-cert.sh --staging, затем --production (docs/certificate.md)"
info ""
info "Проверка публикации портов после 'docker compose up -d':"
info "  cd $MC && docker compose config | grep -A3 'host_ip: $BACKEND_OVERLAY_IP' | grep -E 'published|target'"
