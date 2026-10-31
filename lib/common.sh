# shellcheck shell=bash
# Переменные ниже читают и меняют подключающие скрипты.
# shellcheck disable=SC2034
# Общие функции скриптов gateway/ и backend/: загрузка настроек, проверка значений,
# рендер шаблонов, показ diff и установка файлов.
#
# Подключается из скриптов, которые сами включают set -euo pipefail.
# Совместимо с bash 3.2, чтобы --render и --dry-run можно было запускать на рабочей машине.

MEG_VERSION=0.1.0
DOCS_URL=https://pugemon.github.io/mailcow-edge-gateway

TS=$(date +%Y%m%d-%H%M%S)
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}   # --yes: не спрашивать подтверждение
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/mailcow-edge-gateway}
CHANGED=0   # сколько файлов изменено (в --dry-run — сколько было бы изменено)
APPLIED=0   # 1, если последний вызов apply_file изменил (изменил бы) файл
BACKED_UP=0 # 1, если хотя бы один существующий файл сохранён в $BACKUP_ROOT/$TS
PENDING=""  # файлы к установке: строки "MODE<TAB>NEW<TAB>DST" (см. apply_file, commit_changes)
STAGE=""

# Цвет — только в терминале, без NO_COLOR (https://no-color.org) и не для TERM=dumb.
color_ok() { [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; }
C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_RESET=""
if [ -t 1 ] && color_ok; then
  C_BOLD=$'\033[1m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_RESET=$'\033[0m'
fi
E_YELLOW="" E_RED="" E_RESET=""
if [ -t 2 ] && color_ok; then
  E_YELLOW=$'\033[33m' E_RED=$'\033[31m' E_RESET=$'\033[0m'
fi

log()  { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sOK%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sВНИМАНИЕ:%s %s\n' "$E_YELLOW" "$E_RESET" "$*" >&2; }
die()  { printf '%sОШИБКА:%s %s\n' "$E_RED" "$E_RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# die_usage MESSAGE — ошибка в аргументах командной строки (код возврата 2).
die_usage() {
  printf '%sОШИБКА:%s %s\nСправка: %s --help\n' "$E_RED" "$E_RESET" "$*" "$0" >&2
  exit 2
}

print_version() { printf 'mailcow-edge-gateway %s\n' "$MEG_VERSION"; }

# confirm QUESTION — спросить «да/нет» в терминале. С --yes (ASSUME_YES=1) ответ «да» без вопроса.
# Без терминала и без --yes — ошибка: менять систему без явного согласия скрипт не будет.
confirm() {
  local answer=""
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || die "нужно подтверждение, а терминала нет: запустите с --yes (план изменений — --dry-run)"
  printf '%s%s%s [y/N] ' "$C_BOLD" "$1" "$C_RESET"
  read -r answer || true
  case $answer in y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;; esac
  return 1
}

# cancel — пользователь отказался от изменений.
cancel() {
  printf 'Отменено: %s\n' "${1:-ничего не изменено}" >&2
  exit 1
}

is_root() { [ "$(id -u)" -eq 0 ]; }
need_root() {
  is_root || die "нужны права root (запустите через sudo или используйте --dry-run)"
}

# run CMD... — выполнить команду, а в режиме --dry-run только показать её.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# make_stage — временный каталог для рендера и правки копий файлов; удаляется при выходе.
make_stage() {
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mailcow-edge.XXXXXX")
  trap 'rm -rf "$STAGE"' EXIT
}

# ---------------------------------------------------------------- настройки

# load_conf FILE — прочитать файл настроек (KEY=VALUE в синтаксисе shell) и экспортировать переменные.
load_conf() {
  local f=$1
  [ -f "$f" ] || die "нет файла настроек $f (скопируйте пример из examples/ и заполните)"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# require_vars VAR... — все перечисленные настройки обязательны и не пустые.
require_vars() {
  local v missing=""
  for v in "$@"; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || die "в файле настроек не заданы:$missing"
}

# set_default VAR VALUE — значение по умолчанию для необязательной настройки (пустое значение
# в файле настроек сохраняется как есть).
set_default() {
  local name=$1 value=$2
  if [ -z "${!name+x}" ]; then
    printf -v "$name" '%s' "$value"
  fi
  export "${name?}"
}

is_ipv4() {
  local ip=$1 o re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  [[ $ip =~ $re ]] || return 1
  local IFS=.
  for o in $ip; do
    [ "$((10#$o))" -le 255 ] || return 1
  done
}

is_cidr4() {
  local len
  case $1 in */*) len=${1#*/} ;; *) return 1 ;; esac
  is_ipv4 "${1%/*}" || return 1
  [[ $len =~ ^[0-9]{1,2}$ ]] && [ "$len" -le 32 ]
}

is_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_fqdn() {
  local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$'
  [[ $1 =~ $re ]]
}

is_ifname() {
  local re='^[A-Za-z0-9_.-]{1,15}$'
  [[ $1 =~ $re ]]
}

is_yesno() {
  case $1 in yes|no) return 0 ;; esac
  return 1
}

# check VALIDATOR VAR — проверить значение настройки VAR функцией VALIDATOR.
check() {
  local fn=$1 name=$2
  "$fn" "${!name}" || die "некорректное значение $name='${!name}'"
}

# ---------------------------------------------------------------- почтовые сервисы

# Сервисы mailcow, которые публикуются через шлюз: публичный порт на шлюзе, порт haproxy-listener
# в mailcow (принимает PROXY v2) и переменная mailcow.conf, задающая адрес публикации этого порта.
ALL_SERVICES="smtp smtps submission imap imaps pop3 pop3s sieve"

svc_public_port() {
  case $1 in
    smtp) echo 25 ;; smtps) echo 465 ;; submission) echo 587 ;;
    imap) echo 143 ;; imaps) echo 993 ;;
    pop3) echo 110 ;; pop3s) echo 995 ;;
    sieve) echo 4190 ;;
    *) return 1 ;;
  esac
}

svc_proxy_port() {
  case $1 in
    smtp) echo 10025 ;; smtps) echo 10465 ;; submission) echo 10587 ;;
    imap) echo 10143 ;; imaps) echo 10993 ;;
    pop3) echo 10110 ;; pop3s) echo 10995 ;;
    sieve) echo 14190 ;;
    *) return 1 ;;
  esac
}

svc_mailcow_var() {
  case $1 in
    smtp) echo SMTP_PORT_HAPROXY ;; smtps) echo SMTPS_PORT_HAPROXY ;;
    submission) echo SUBMISSION_PORT_HAPROXY ;;
    imap) echo IMAP_PORT_HAPROXY ;; imaps) echo IMAPS_PORT_HAPROXY ;;
    pop3) echo POP_PORT_HAPROXY ;; pop3s) echo POPS_PORT_HAPROXY ;;
    sieve) echo SIEVE_PORT_HAPROXY ;;
    *) return 1 ;;
  esac
}

svc_enabled() {
  case " $SERVICES " in *" $1 "*) return 0 ;; esac
  return 1
}

validate_services() {
  local s
  for s in $SERVICES; do
    svc_public_port "$s" >/dev/null || die "неизвестный сервис '$s' в SERVICES (допустимо: $ALL_SERVICES)"
  done
  svc_enabled smtp || warn "smtp (порт 25) не входит в SERVICES — входящая почта из интернета приниматься не будет"
}

# port_list PORT... — уникальные порты по возрастанию через запятую (для множеств nftables).
port_list() {
  printf '%s\n' "$@" | sort -n -u | paste -s -d, - | sed 's/,/, /g'
}

# Все PROXY-порты mailcow (независимо от SERVICES): фильтры nftables закрывают их все.
all_proxy_ports() {
  local s ports=""
  for s in $ALL_SERVICES; do
    ports="$ports $(svc_proxy_port "$s")"
  done
  # shellcheck disable=SC2086
  port_list $ports
}

# ---------------------------------------------------------------- файлы

# render_template TEMPLATE OUT — подставить {{VAR}} из окружения (переменные должны быть
# экспортированы). Незаданная переменная — ошибка. Без внешних зависимостей (только awk).
render_template() {
  local tmpl=$1 out=$2
  mkdir -p "$(dirname "$out")"
  awk '
    {
      line = $0; res = ""
      while (match(line, /[{][{][A-Z0-9_]+[}][}]/)) {
        name = substr(line, RSTART + 2, RLENGTH - 4)
        if (!(name in ENVIRON)) {
          printf "%s:%d: не задана переменная %s\n", FILENAME, FNR, name > "/dev/stderr"
          bad = 1
        }
        res = res substr(line, 1, RSTART - 1) ENVIRON[name]
        line = substr(line, RSTART + RLENGTH)
      }
      print res line
    }
    END { exit bad }
  ' "$tmpl" > "$out" || die "не удалось подготовить файл из шаблона $tmpl"
}

# stage_copy DST — путь к копии DST во временном каталоге (пустой файл, если DST нет).
# Правки делаются в копии, затем apply_file показывает diff и устанавливает результат.
stage_copy() {
  local dst=$1 s="$STAGE/edit$1"
  mkdir -p "$(dirname "$s")"
  if [ -f "$dst" ]; then
    cp -p "$dst" "$s"
  else
    : > "$s"
  fi
  printf '%s\n' "$s"
}

# apply_file NEW DST [MODE] — показать diff между установленным DST и NEW и, если они различаются,
# поставить NEW в очередь на установку. Сами файлы меняет commit_changes — после того как показан
# весь план и получено подтверждение. NEW не должен меняться до commit_changes.
# Результат — в APPLIED (1 — файл будет изменён), счётчик CHANGED увеличивается.
apply_file() {
  local new=$1 dst=$2 mode=${3:-0644} old=$2
  APPLIED=0
  if [ -f "$dst" ] && cmp -s "$new" "$dst"; then
    info "без изменений: $dst"
    return 0
  fi
  [ -f "$dst" ] || old=/dev/null
  printf -- '--- %s\n' "$dst"
  diff -u -L "$dst (сейчас)" -L "$dst (будет)" "$old" "$new" | sed 's/^/    /' || true
  APPLIED=1
  CHANGED=$((CHANGED + 1))
  PENDING="$PENDING$mode"$'\t'"$new"$'\t'"$dst"$'\n'
}

# install_file NEW DST MODE — установить NEW на место DST. Предыдущая версия сохраняется
# в $BACKUP_ROOT/<время>/<путь>; владелец и права существующего файла сохраняются, новый файл
# создаётся с правами MODE.
install_file() {
  local new=$1 dst=$2 mode=$3
  if [ -f "$dst" ]; then
    mkdir -p "$BACKUP_ROOT/$TS$(dirname "$dst")"
    cp -p "$dst" "$BACKUP_ROOT/$TS$dst"
    cat "$new" > "$dst"
    BACKED_UP=1
    info "обновлён: $dst (старая версия: $BACKUP_ROOT/$TS$dst)"
  else
    mkdir -p "$(dirname "$dst")"
    install -m "$mode" "$new" "$dst"
    info "создан: $dst"
  fi
}

# commit_changes [QUESTION] — спросить подтверждение (confirm) и установить файлы из очереди
# apply_file. В --dry-run и когда менять нечего — ничего не делает. Отказ — выход без изменений.
commit_changes() {
  local mode new dst
  [ "$DRY_RUN" != 1 ] || return 0
  [ -n "$PENDING" ] || return 0
  confirm "${1:-Применить изменения (файлов: $CHANGED)?}" || cancel "файлы не изменены"
  log "Установка файлов"
  while IFS=$'\t' read -r mode new dst; do
    [ -n "$dst" ] || continue
    install_file "$new" "$dst" "$mode"
  done <<EOF
$PENDING
EOF
  PENDING=""
}

# ensure_newline FILE — дописать перевод строки, если файл не пуст и не заканчивается им.
ensure_newline() {
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then
    echo >> "$1"
  fi
}

# set_kv FILE KEY VALUE — строка KEY=VALUE (формат mailcow.conf): заменить или дописать.
set_kv() {
  local f=$1 k=$2 v=$3
  if grep -q "^$k=" "$f"; then
    sed -i.sedtmp "s|^$k=.*|$k=$v|" "$f" && rm -f "$f.sedtmp"
  else
    ensure_newline "$f"
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# set_param FILE KEY VALUE [COMMENT] — строка "KEY = VALUE" (Postfix, Dovecot): заменить или
# дописать; при дописывании перед строкой ставится комментарий COMMENT (может быть многострочным).
set_param() {
  local f=$1 k=$2 v=$3 comment=${4:-}
  if grep -Eq "^${k}[[:space:]]*=" "$f"; then
    sed -i.sedtmp -E "s|^${k}[[:space:]]*=.*|$k = $v|" "$f" && rm -f "$f.sedtmp"
  else
    ensure_newline "$f"
    if [ -n "$comment" ]; then
      printf '%s\n' "$comment" >> "$f"
    fi
    printf '%s = %s\n' "$k" "$v" >> "$f"
  fi
}
