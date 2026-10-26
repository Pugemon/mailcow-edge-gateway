#!/usr/bin/env bash
# Сертификат mailcow через acme.sh и DNS-01. Не зависит от того, куда указывают A-записи и кто
# обслуживает порт 80 (на шлюзе он занят reverse proxy), поэтому сертификат можно получить
# заранее, до переключения MX. Подробно — docs/certificate.md.
#
#   --staging       тестовый выпуск (letsencrypt_test): проверить DNS API и CAA без риска упереться
#                   в лимиты Let's Encrypt; в mailcow не устанавливается
#   --production    боевой выпуск, установка в mailcow (data/assets/ssl), cron продления
#   --install-only  только установить уже выпущенный боевой сертификат и cron
#
# Креды DNS API: перед первым выпуском экспортируйте переменные провайдера (docs/certificate.md);
# acme.sh сохранит их в $ACME_HOME/account.conf, скрипт выставит этому файлу права 600.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SELF_DIR")
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"

usage() {
  cat <<EOF
Использование: backend/issue-cert.sh [-c FILE] (--staging | --production | --install-only) [--force] [--dry-run]

  -c, --config FILE  файл настроек (по умолчанию: backend.conf в корне репозитория)
  --staging          тестовый выпуск через letsencrypt_test
  --production       боевой выпуск и установка в mailcow
  --install-only     установить уже выпущенный сертификат (без выпуска)
  --force            перевыпустить боевой сертификат, даже если он уже есть и не истекает
  --dry-run          показать команды acme.sh, ничего не выполняя
EOF
}

CONF=$REPO_DIR/backend.conf
MODE=""
FORCE=0
while [ $# -gt 0 ]; do
  case $1 in
    -c|--config) CONF=${2:?не указан файл настроек}; shift 2 ;;
    --staging) MODE=staging; shift ;;
    --production) MODE=production; shift ;;
    --install-only) MODE=install; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; die "укажите --staging, --production или --install-only"; }

load_conf "$CONF"
require_vars MAILCOW_DIR MAIL_HOSTNAME ACME_DNS_API
set_default ACME_HOME /root/.acme.sh
set_default ACME_SERVER letsencrypt
set_default ACME_KEYLENGTH 2048
set_default ACME_DNSSLEEP ""
set_default CERT_EXTRA_NAMES ""
set_default CERT_RELOAD_HOOK /usr/local/sbin/mailcow-cert-reload.sh
check is_fqdn MAIL_HOSTNAME
for n in $CERT_EXTRA_NAMES; do
  is_fqdn "$n" || die "некорректное имя в CERT_EXTRA_NAMES: '$n'"
done
case $ACME_DNS_API in dns_*) ;; *) die "ACME_DNS_API должен быть именем DNS API acme.sh (dns_...)" ;; esac
case $ACME_KEYLENGTH in 2048|3072|4096|ec-256|ec-384) ;; *) die "некорректное значение ACME_KEYLENGTH='$ACME_KEYLENGTH'" ;; esac

ACME=$ACME_HOME/acme.sh
SSL_DIR=$MAILCOW_DIR/data/assets/ssl

if [ "$DRY_RUN" != 1 ]; then
  need_root
  [ -x "$ACME" ] || die "acme.sh не найден в $ACME_HOME (установка — docs/certificate.md)"
  [ -d "$SSL_DIR" ] || die "нет каталога $SSL_DIR — проверьте MAILCOW_DIR"
fi

domains=(-d "$MAIL_HOSTNAME")
for n in $CERT_EXTRA_NAMES; do domains+=(-d "$n"); done
ecc=()
domain_dir=$ACME_HOME/$MAIL_HOSTNAME
case $ACME_KEYLENGTH in
  ec-*) ecc=(--ecc); domain_dir=${domain_dir}_ecc ;;
esac
dnssleep=()
if [ -n "$ACME_DNSSLEEP" ]; then dnssleep=(--dnssleep "$ACME_DNSSLEEP"); fi

acme() { run "$ACME" --home "$ACME_HOME" "$@"; }

# Креды DNS API acme.sh хранит в account.conf открытым текстом — только root.
secure_account_conf() {
  if [ -f "$ACME_HOME/account.conf" ]; then
    run chmod 600 "$ACME_HOME/account.conf"
  fi
}

# issue SERVER [ARGS...] — выпуск; код 2 у acme.sh означает «сертификат ещё действителен, пропущено».
issue() {
  local server=$1 rc=0
  shift
  acme --issue --server "$server" --dns "$ACME_DNS_API" "${domains[@]}" \
    --keylength "$ACME_KEYLENGTH" ${dnssleep[@]+"${dnssleep[@]}"} "$@" || rc=$?
  case $rc in
    0) ;;
    2) info "acme.sh: сертификат уже выпущен и не требует продления" ;;
    *) die "acme.sh --issue завершился с кодом $rc (лог: $ACME_HOME/acme.sh.log)" ;;
  esac
}

# API, через который выпущен текущий сертификат (пусто — сертификата ещё нет).
current_api() {
  local f=$domain_dir/$MAIL_HOSTNAME.conf
  if [ -f "$f" ]; then
    sed -n "s/^Le_API='\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" "$f" | tail -n1
  fi
}

install_cert() {
  [ "$DRY_RUN" = 1 ] || [ -x "$CERT_RELOAD_HOOK" ] ||
    die "нет $CERT_RELOAD_HOOK — сначала выполните backend/install.sh"
  log "Установка сертификата в $SSL_DIR"
  acme --install-cert -d "$MAIL_HOSTNAME" ${ecc[@]+"${ecc[@]}"} \
    --key-file "$SSL_DIR/key.pem" \
    --fullchain-file "$SSL_DIR/cert.pem" \
    --reloadcmd "$CERT_RELOAD_HOOK"
  log "Cron продления"
  acme --install-cronjob
  secure_account_conf
  if [ "$DRY_RUN" != 1 ]; then
    log "Установленный сертификат"
    openssl x509 -in "$SSL_DIR/cert.pem" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null ||
      openssl x509 -in "$SSL_DIR/cert.pem" -noout -subject -issuer -enddate
  fi
}

case $MODE in
  staging)
    # Тестовый выпуск поверх боевого запишет в настройки домена у acme.sh тестовый CA, и следующее
    # продление по cron установит в mailcow (по путям --install-cert) недоверенный сертификат.
    case $(current_api) in
      ""|*staging*) ;;
      *) die "боевой сертификат для $MAIL_HOSTNAME уже выпущен — тестовый выпуск переключил бы его продление на тестовый CA" ;;
    esac
    log "Тестовый выпуск (letsencrypt_test) для: $MAIL_HOSTNAME $CERT_EXTRA_NAMES"
    issue letsencrypt_test --force
    secure_account_conf
    info "Тестовый сертификат выпущен (в mailcow не устанавливается). Дальше: --production"
    ;;
  production)
    # По умолчанию acme.sh использует ZeroSSL; если CAA домена разрешает только Let's Encrypt,
    # выпуск через ZeroSSL не пройдёт. Сервер по умолчанию — для продления и новых сертификатов.
    acme --set-default-ca --server "$ACME_SERVER"
    api=$(current_api)
    if [ "$FORCE" = 1 ]; then
      log "Боевой выпуск (--force)"
      issue "$ACME_SERVER" --force
    elif [ -z "$api" ]; then
      log "Боевой выпуск"
      issue "$ACME_SERVER"
    else
      case $api in
        *staging*)
          # После тестового выпуска acme.sh считает сертификат действующим — нужен --force.
          log "Боевой выпуск (заменяет тестовый сертификат)"
          issue "$ACME_SERVER" --force
          ;;
        *)
          info "боевой сертификат уже выпущен ($api); продление — по cron, перевыпуск — --force"
          ;;
      esac
    fi
    install_cert
    ;;
  install)
    case $(current_api) in
      "") die "сертификат для $MAIL_HOSTNAME ещё не выпущен — запустите с --production" ;;
      *staging*) die "выпущен только тестовый сертификат — запустите с --production" ;;
    esac
    install_cert
    ;;
esac
