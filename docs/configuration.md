# Конфигурация

Настройки — два файла в корне репозитория в формате shell (`KEY=VALUE`, значения с пробелами —
в кавычках): `gateway.conf` на шлюзе и `backend.conf` на бэкенде. Оба в `.gitignore`; примеры —
в `examples/`. Другой путь — `-c FILE`.

Адреса `GATEWAY_*`, `BACKEND_OVERLAY_IP`, `RELAY_PORT` и `SERVICES` в обоих файлах должны совпадать.
Скрипты проверяют значения (адреса, порты, имена, интерфейсы) до любых изменений и называют
ошибочную настройку.

## gateway.conf {#gateway-conf}

| Параметр | По умолчанию | Назначение |
|---|---|---|
| `GATEWAY_PUBLIC_IPV4` | обязателен | публичный IPv4 шлюза: на нём HAProxy, с него relay отправляет почту; PTR = `MAIL_HOSTNAME`, адрес входит в SPF |
| `GATEWAY_OVERLAY_IP` | обязателен | адрес шлюза в оверлейной сети |
| `BACKEND_OVERLAY_IP` | обязателен | адрес бэкенда в оверлее: на нём опубликованы PROXY-порты mailcow |
| `OVERLAY_IFACE` | обязателен | интерфейс оверлея на шлюзе (`wg0` и т.п.) |
| `OVERLAY_SERVICE` | пусто | systemd-юнит клиента оверлея (`wg-quick@wg0.service`); HAProxy стартует после него |
| `MAIL_HOSTNAME` | обязателен | публичное имя mailcow; relay представляется им наружу (HELO) |
| `RELAY_HOSTNAME` | обязателен | `myhostname` relay; **обязательно** отличается от `MAIL_HOSTNAME`, DNS-запись не нужна |
| `SERVICES` | обязателен | публикуемые сервисы: `smtp smtps submission imap imaps pop3 pop3s sieve` |
| `SMTP_ALLOWLIST_ENABLED` | `yes` | `yes` — порт 25 только для `SMTP_ALLOWLIST` (до переключения MX); `no` — для всех |
| `SMTP_ALLOWLIST` | пусто | адреса для тестов порта 25 (`a.b.c.d` или `a.b.c.d/nn` через пробел); адрес шлюза добавляется сам |
| `HAPROXY_DENY_SRC_EXTRA` | пусто | дополнительные сети, из которых HAProxy отклоняет соединения (к частным и служебным) |
| `HAPROXY_MAXCONN` | `4000` | `maxconn` HAProxy |
| `HAPROXY_TIMEOUT_CONNECT` | `10s` | таймаут соединения с бэкендом |
| `HAPROXY_TIMEOUT` | `10m` | таймаут неактивности SMTP, POP3, ManageSieve |
| `HAPROXY_TIMEOUT_IMAP` | `35m` | таймаут IMAP: IDLE держится до 29 минут |
| `RELAY_PORT` | обязателен | порт relay на шлюзе (в примере `2525`; не 25) |
| `RELAY_INET_PROTOCOLS` | `ipv4` | `inet_protocols` relay: `ipv4`, если у VPS нет PTR для IPv6 |
| `RELAY_MESSAGE_SIZE_LIMIT` | `104857600` | максимальный размер письма на relay, байт |

??? example "Пример целиком — examples/gateway.conf"

    ```sh
    --8<-- "examples/gateway.conf"
    ```

## backend.conf {#backend-conf}

| Параметр | По умолчанию | Назначение |
|---|---|---|
| `MAILCOW_DIR` | обязателен | каталог mailcow-dockerized |
| `BACKEND_OVERLAY_IP` | обязателен | адрес бэкенда в оверлее: на нём публикуются PROXY-порты |
| `GATEWAY_OVERLAY_IP` | обязателен | адрес шлюза в оверлее: только ему открыты PROXY-порты; ему доверяют Dovecot и nginx; на нём relay |
| `GATEWAY_PUBLIC_IPV4` | обязателен | публичный адрес шлюза: единственный внешний адрес, куда контейнерам mailcow разрешён tcp/25 |
| `OVERLAY_IFACE` | обязателен | интерфейс оверлея на бэкенде |
| `MAILCOW_BRIDGE` | `br-mailcow` | bridge-интерфейс Docker-сети mailcow |
| `SERVICES` | обязателен | как в `gateway.conf`; PROXY-порты невключённых сервисов остаются на `127.0.0.1` |
| `RELAY_PORT` | обязателен | порт relay на шлюзе: `relayhost = [GATEWAY_OVERLAY_IP]:RELAY_PORT` |
| `CONFIGURE_RELAYHOST` | `yes` | прописать `relayhost` в `data/conf/postfix/extra.cf` |
| `SKIP_LETS_ENCRYPT` | `y` | выключить встроенный ACME mailcow: сертификат выпускает acme.sh через DNS-01 |
| `MAILCOW_HTTP_PORT` | `80` | `HTTP_PORT` mailcow — для запрета IPv6 на него |
| `MAILCOW_HTTPS_PORT` | `443` | `HTTPS_PORT` mailcow — для запрета IPv6 и проксирования веба |
| `MAIL_HOSTNAME` | обязателен для сертификата | имя в сертификате почтовых портов (`MAILCOW_HOSTNAME`) |
| `CERT_EXTRA_NAMES` | пусто | дополнительные имена в сертификате (обычно не нужны) |
| `ACME_HOME` | `/root/.acme.sh` | каталог acme.sh (там же `account.conf` с кредами DNS API) |
| `ACME_DNS_API` | обязателен для сертификата | DNS API acme.sh, имя вида `dns_xxx` ([список](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)) |
| `ACME_SERVER` | `letsencrypt` | CA для выпуска и продления |
| `ACME_KEYLENGTH` | `2048` | тип ключа: `2048`, `3072`, `4096`, `ec-256`, `ec-384` |
| `ACME_DNSSLEEP` | пусто | пауза после создания TXT-записи, сек.; пусто — acme.sh проверяет сам |
| `CERT_RELOAD_HOOK` | `/usr/local/sbin/mailcow-cert-reload.sh` | команда после выпуска и продления (ставит `backend/install.sh`) |

??? example "Пример целиком — examples/backend.conf"

    ```sh
    --8<-- "examples/backend.conf"
    ```

## Порты {#ports}

| Сервис | Порт на шлюзе | PROXY-порт mailcow | Переменная в `mailcow.conf` |
|---|---|---|---|
| smtp | 25 | 10025 | `SMTP_PORT_HAPROXY` |
| smtps | 465 | 10465 | `SMTPS_PORT_HAPROXY` |
| submission | 587 | 10587 | `SUBMISSION_PORT_HAPROXY` |
| imap | 143 | 10143 | `IMAP_PORT_HAPROXY` |
| imaps | 993 | 10993 | `IMAPS_PORT_HAPROXY` |
| pop3 | 110 | 10110 | `POP_PORT_HAPROXY` |
| pop3s | 995 | 10995 | `POPS_PORT_HAPROXY` |
| sieve | 4190 | 14190 | `SIEVE_PORT_HAPROXY` |

По умолчанию pop3 (110) не публикуется — хватает 995. Relay Postfix на шлюзе слушает `RELAY_PORT`
(`2525`) и принимает почту только от бэкенда. Таблицы nftables закрывают все PROXY-порты,
независимо от `SERVICES`.

## Какие файлы меняются

| Где | Файл | Как |
|---|---|---|
| шлюз | `/etc/haproxy/haproxy.cfg`, `deny-src.lst`, `smtp-allow.lst` | целиком из `gateway/templates/` |
| шлюз | `/etc/mail-edge.nft`, `/etc/systemd/system/mail-edge.service` | целиком из шаблонов |
| шлюз | `/etc/systemd/system/haproxy.service.d/mail-edge.conf` | целиком из шаблона |
| шлюз | `/etc/postfix/main.cf`, `master.cf` | отдельные параметры через `postconf` |
| бэкенд | `/etc/mailcow-edge.nft`, `/etc/systemd/system/mailcow-edge.service` | целиком из `backend/templates/` |
| бэкенд | `/etc/sysctl.d/90-mailcow-nonlocal-bind.conf`, `/usr/local/sbin/mailcow-cert-reload.sh` | целиком из шаблонов |
| бэкенд | `/etc/docker/daemon.json` | только ключ `"userland-proxy": false` |
| бэкенд | `mailcow.conf` | `SKIP_LETS_ENCRYPT` и `*_PORT_HAPROXY` |
| бэкенд | `docker-compose.override.yml` | копия из `helper-scripts/…/HAPROXY/`, если своего нет |
| бэкенд | `data/conf/dovecot/extra.conf` | `haproxy_trusted_networks` |
| бэкенд | `data/conf/nginx/site.real-ip-gateway.custom` | `set_real_ip_from` (и `real_ip_header`, если его нет в `nginx -T`) |
| бэкенд | `data/conf/postfix/extra.cf` | `relayhost` |

## Изменение настроек

Правьте `gateway.conf` / `backend.conf`, затем `--dry-run` и повторный запуск того же скрипта:

```sh
sudo gateway/install.sh --dry-run   # что изменится
sudo gateway/install.sh             # применить (с подтверждением; --yes — без)
```

Файлы, которые создаются целиком из шаблонов, перезаписываются при каждом запуске — ручные правки
в них пропадут; меняйте шаблоны в `gateway/templates/` и `backend/templates/`. Предыдущие версии
изменённых файлов — в `/var/backups/mailcow-edge-gateway/<время>/`.
