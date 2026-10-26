# mailcow-edge-gateway

Публикация [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized), который стоит в офисе
или за NAT, через внешний VPS (шлюз):

- **входящие почтовые порты** (25, 465, 587, 143, 993, 995, 4190) принимает HAProxy на шлюзе и передаёт
  в mailcow по PROXY protocol v2 — mailcow видит реальные IP клиентов, поэтому postscreen, DNSBL, SPF,
  rspamd и fail2ban работают как при прямом подключении;
- **исходящая почта** уходит через relay Postfix на шлюзе — с адреса VPS, у которого правильные PTR и SPF;
- **связь шлюз ↔ mailcow** — оверлейная сеть (WireGuard или mesh-VPN): в офисе не нужны белый IP
  и проброс портов;
- **веб** (SOGo, админка, autodiscover/autoconfig, MTA-STS) — через reverse proxy на шлюзе
  (в примерах — Nginx Proxy Manager).

TLS на почтовых портах терминирует сам mailcow: на шлюзе нет ни сертификата почты, ни паролей
пользователей, ни писем.

## Когда это нужно

- mailcow должен работать на своём железе (данные остаются в офисе), но у офиса нет статического
  белого IPv4, провайдер не даёт PTR или блокирует порт 25;
- офисный адрес «грязный» (динамический пул в DNSBL) и отправлять с него почту нельзя;
- нужно вывести почту наружу, не открывая в офисной сети ни одного входящего порта.

Если mailcow можно поставить прямо на сервер с нормальным публичным адресом — этот репозиторий не нужен.

## Схема

```
                       клиенты и почтовые серверы в интернете
                                     │
               MX, mail.example.com  │  A и PTR: 203.0.113.10 <-> mail.example.com
                                     ▼
+----------- шлюз (VPS): 203.0.113.10, оверлей 100.64.0.10 -----------+
|                                                                     |
|  HAProxy, mode tcp             reverse proxy (NPM)     Postfix      |
|  25 465 587 143 993 995 4190   80, 443                 relay :2525 -+--> MX получателей
|  deny-src, allowlist на 25           |                     ^        |    (с 203.0.113.10)
|       |                              |                     |        |
+-------|------------------------------|---------------------|--------+
        | PROXY v2                     | HTTPS               | SMTP
~~~~~~~~|~~~~~~~~ оверлей ~~~~~~~~~~~~~|~~~~~~~~~~~~~~~~~~~~~|~~~~~~~~~~
        |                              |                     |
+-------|------------------------------|---------------------|--------+
|       v                              v                     |        |
|  100.64.0.20:10025 ... 14190    nginx-mailcow :443         |        |
|  haproxy-listeners              set_real_ip_from шлюза     |        |
|  Postfix, Dovecot                                          |        |
|                                 postfix-mailcow: relayhost |        |
|                                 [100.64.0.10]:2525 --------+        |
|                                                                     |
+------ бэкенд (офис, за NAT): mailcow, оверлей 100.64.0.20 ----------+
```

Адреса в примерах: публичный адрес шлюза `203.0.113.10`, шлюз в оверлее `100.64.0.10`,
бэкенд (сервер mailcow) в оверлее `100.64.0.20`, домен `example.com`.

### Порты

| Сервис     | Порт на шлюзе | PROXY-порт mailcow | Переменная в mailcow.conf  |
|------------|---------------|--------------------|----------------------------|
| smtp       | 25            | 10025              | `SMTP_PORT_HAPROXY`        |
| smtps      | 465           | 10465              | `SMTPS_PORT_HAPROXY`       |
| submission | 587           | 10587              | `SUBMISSION_PORT_HAPROXY`  |
| imap       | 143           | 10143              | `IMAP_PORT_HAPROXY`        |
| imaps      | 993           | 10993              | `IMAPS_PORT_HAPROXY`       |
| pop3       | 110           | 10110              | `POP_PORT_HAPROXY`         |
| pop3s      | 995           | 10995              | `POPS_PORT_HAPROXY`        |
| sieve      | 4190          | 14190              | `SIEVE_PORT_HAPROXY`       |

Набор публикуемых сервисов задаётся `SERVICES`; по умолчанию pop3 (110) не публикуется — хватает 995.
Relay Postfix на шлюзе слушает `2525` и принимает почту только от бэкенда.

### Как устроено и главное ограничение

Postfix в mailcow **доверяет любому PROXY-заголовку**: списка доверенных отправителей заголовка у него
нет. Кто может подключиться к PROXY-порту mailcow, тот может написать в заголовке `127.0.0.1` или адрес
из mynetworks и получить open relay. Поэтому доступ к PROXY-портам закрыт тремя независимыми барьерами:

1. **бэкенд** — nftables, цепочка `prerouting` (priority mangle): к PROXY-портам только с адреса шлюза
   через интерфейс оверлея, остальное — drop;
2. **шлюз** — nftables, цепочка `output`: к PROXY-портам бэкенда может подключаться только пользователь
   `haproxy` (`meta skuid`); транзитный трафик (контейнеры Docker на шлюзе) — drop в `prerouting`;
3. **HAProxy** — на каждом входе `tcp-request connection reject` для источников из частных и служебных
   сетей (`deny-src.lst`: 127/8, 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, 0/8).

Подробно — модель угроз, причины каждого решения и подводные камни — в [docs/design.md](docs/design.md).

## Требования

**Шлюз (VPS)**
- статический публичный IPv4, PTR которого можно выставить на `mail.example.com`;
- Linux с apt и debconf, systemd и nftables: пакеты haproxy, nftables и postfix скрипты ставят
  через apt;
- если на шлюзе есть свой firewall (ufw и т.п.) с запретом входящих по умолчанию — откройте в нём
  почтовые порты и 80/443; порт relay (2525) закрывает таблица `mail_edge` из этого репозитория.

**Бэкенд (сервер mailcow)**
- mailcow-dockerized с поддержкой haproxy-listeners
  (`helper-scripts/docker-compose.override.yml.d/HAPROXY/` в каталоге mailcow);
- nftables (`nft`), systemd; python3 или jq (для правки `/etc/docker/daemon.json`).

**Оверлейная сеть**
- оба узла в одной сети (WireGuard или mesh-VPN) с постоянными адресами;
- между шлюзом и бэкендом разрешён трафик в обе стороны; маршрут по умолчанию через туннель не нужен
  (для WireGuard: `AllowedIPs` — только `/32` адрес соседа).

**DNS и сертификат**
- управление зоной домена; для сертификата mailcow — DNS API, который поддерживает
  [acme.sh](https://github.com/acmesh-official/acme.sh) (DNS-01).

## Состав

```
README.md
gateway/                    шлюз (VPS)
  install.sh                HAProxy + nftables mail_edge + вызов setup-relay.sh
  setup-relay.sh            Postfix relay для исходящей почты
  templates/                haproxy.cfg, deny-src.lst, mail-edge.nft, mail-edge.service, drop-in HAProxy
backend/                    сервер mailcow
  install.sh                nftables mailcow_edge, sysctl, mailcow.conf, override, Dovecot, nginx,
                            relayhost, userland-proxy, хук сертификата
  issue-cert.sh             сертификат через acme.sh и DNS-01
  templates/                mailcow-edge.nft, mailcow-edge.service, sysctl, mailcow-cert-reload.sh
lib/common.sh               общие функции: настройки, рендер шаблонов, diff, установка файлов
tools/
  check-tls.sh              TLS и сертификат на всех почтовых портах
  check-relay.sh            проверка на open relay (до DATA, письмо не отправляется)
docs/                       устройство и модель угроз, reverse proxy, сертификат, MTA-STS, отладка
examples/                   gateway.conf, backend.conf, конфиги reverse proxy
```

Все скрипты:
- читают настройки из одного файла (`gateway.conf` / `backend.conf`, формат `KEY=VALUE`);
- подставляют их в шаблоны (`{{VAR}}`, только awk — без лишних зависимостей);
- поддерживают `--dry-run`: показывают diff с установленными файлами и ничего не меняют;
- идемпотентны: повторный запуск с теми же настройками ничего не меняет;
- сохраняют предыдущие версии изменённых файлов в `/var/backups/mailcow-edge-gateway/<время>/`.

`gateway/install.sh --render DIR` и `backend/install.sh --render DIR` записывают готовые конфиги
в каталог без root — их можно посмотреть на рабочей машине до установки.

## Установка

Порядок: **сначала бэкенд, потом шлюз**, затем веб и MTA-STS. После каждого шага — проверки.
До переключения MX (см. «[Переключение](#переключение)») внешняя почта продолжает идти к старому
провайдеру: порт 25 шлюза открыт только для тестовых адресов, автонастройка клиентов закрыта.

### 0. Подготовка

1. Подключите шлюз и бэкенд к оверлейной сети, запишите их адреса (здесь `100.64.0.10` и `100.64.0.20`).
   Проверьте связность: `ping 100.64.0.20` со шлюза.
2. DNS (MX пока не трогать):
   - `A mail.example.com → 203.0.113.10`;
   - PTR `203.0.113.10 → mail.example.com` (в панели хостера VPS);
   - SPF: добавьте `ip4:203.0.113.10` к существующей записи, старого провайдера не убирайте.
3. Скопируйте репозиторий на оба узла (например, в `/opt/mailcow-edge-gateway`).

### 1. Бэкенд (сервер mailcow)

```sh
cd /opt/mailcow-edge-gateway
cp examples/backend.conf backend.conf
$EDITOR backend.conf                  # адреса, MAILCOW_DIR, SERVICES, DNS API для сертификата

sudo backend/install.sh --dry-run     # посмотреть diff
sudo backend/install.sh
```

Скрипт меняет только файлы. Применить изменения:

```sh
sudo systemctl restart docker         # если менялся /etc/docker/daemon.json (userland-proxy=false);
                                      # перезапустит все контейнеры на хосте
cd /opt/mailcow-dockerized
sudo docker compose up -d             # опубликовать PROXY-порты на 100.64.0.20
```

Если `docker-compose.override.yml` у вас уже был, скрипт остановится и попросит слить его с
`helper-scripts/docker-compose.override.yml.d/HAPROXY/docker-compose.override.yml` вручную
(секции `ports` у `postfix-mailcow` и `dovecot-mailcow`).

**Whitelist шлюза в Fail2ban mailcow.** В интерфейсе администратора mailcow, в параметрах Fail2ban
(Netfilter), добавьте `100.64.0.10/32` в список разрешённых сетей/хостов. Иначе однажды Netfilter
забанит адрес шлюза (например, за ошибки авторизации, пришедшие через веб), и вместе с ним отвалится
вся внешняя почта и веб.

**Сертификат** (DNS-01, подробно — [docs/certificate.md](docs/certificate.md)):

```sh
# acme.sh установлен, креды DNS API экспортированы (docs/certificate.md)
sudo backend/issue-cert.sh --staging      # тестовый выпуск: DNS API, CAA, пропагация
sudo backend/issue-cert.sh --production   # боевой выпуск, установка в mailcow, cron продления
```

**Проверки после шага 1** (на бэкенде):

```sh
sudo nft list table inet mailcow_edge             # таблица загружена
sysctl net.ipv4.ip_nonlocal_bind                  # = 1
pgrep -a docker-proxy || echo "docker-proxy нет"  # userland-proxy выключен

cd /opt/mailcow-dockerized
sudo docker compose ps postfix-mailcow dovecot-mailcow
#   в PORTS: 100.64.0.20:10025->10025/tcp, ... 100.64.0.20:14190->14190/tcp
sudo docker compose exec postfix-mailcow postconf relayhost                 # [100.64.0.10]:2525
sudo docker compose exec dovecot-mailcow doveconf haproxy_trusted_networks  # 100.64.0.10/32
sudo docker compose exec nginx-mailcow nginx -t                             # syntax is ok
openssl x509 -in data/assets/ssl/cert.pem -noout -subject -issuer -enddate  # Let's Encrypt, не staging
```

С любого узла оверлея, кроме шлюза, и из контейнера вне сети mailcow — PROXY-порты недоступны
(ожидается таймаут, т.к. в prerouting только drop):

```sh
nc -zv -w5 100.64.0.20 10025                                    # с другого узла оверлея / LAN
sudo docker run --rm alpine nc -zv -w5 100.64.0.20 10025        # на бэкенде, контейнер вне mailcow
```

### 2. Шлюз (VPS)

```sh
cd /opt/mailcow-edge-gateway
cp examples/gateway.conf gateway.conf
$EDITOR gateway.conf                  # адреса, MAIL_HOSTNAME, RELAY_HOSTNAME, SMTP_ALLOWLIST

sudo gateway/install.sh --dry-run     # diff конфигов HAProxy/nftables и параметров Postfix
sudo gateway/install.sh               # пакеты, nftables mail_edge, HAProxy, relay Postfix
```

В `SMTP_ALLOWLIST` добавьте внешний адрес офиса и адреса машин, с которых будете тестировать порт 25;
публичный адрес самого шлюза добавляется автоматически.

**Проверки после шага 2.** На шлюзе:

```sh
sudo haproxy -c -f /etc/haproxy/haproxy.cfg                  # Configuration file is valid
sudo ss -ltnp | grep haproxy        # 203.0.113.10:25 465 587 143 993 995 4190
sudo ss -ltnp | grep ':2525'        # master (postfix)
sudo nft list table inet mail_edge

# барьер 2: никто, кроме пользователя haproxy, не подключится к PROXY-порту бэкенда
sudo -u nobody bash -c 'exec 3<>/dev/tcp/100.64.0.20/10025'  # Connection refused
sudo bash -c 'exec 3<>/dev/tcp/100.64.0.20/10025'            # root тоже: Connection refused
```

С внешней машины из `SMTP_ALLOWLIST` (или с самого шлюза):

```sh
tools/check-tls.sh mail.example.com     # на всех портах OK, Verify return code: 0
tools/check-relay.sh mail.example.com   # OK: relay запрещён (554 Relay access denied)
nc -zv -w5 203.0.113.10 2525            # снаружи relay недоступен: таймаут
```

Реальный IP клиента виден в логах mailcow (на бэкенде) — там должен быть адрес вашей внешней машины,
а не `100.64.0.10`:

```sh
sudo docker compose logs --since 10m postfix-mailcow | grep -E 'CONNECT from|connect from'
sudo docker compose logs --since 10m dovecot-mailcow | grep 'rip='
```

Исходящая почта: отправьте письмо из SOGo на внешний ящик (или
`printf 'Subject: relay test\n\ntest\n' | sudo docker compose exec -T postfix-mailcow sendmail -f postmaster@example.com you@example.net`).
На шлюзе письмо проходит через relay:

```sh
sudo journalctl --since '10 min ago' | grep -E 'postfix/(from-mailcow/smtpd|smtp)\['   # status=sent
```

У получателя в заголовках: `spf=pass` (203.0.113.10) и `dkim=pass`.

### 3. Веб: reverse proxy

Один proxy host на все веб-имена (`mail.`, `autodiscover.`, `autoconfig.`, `mta-sts.` каждого домена)
→ `https://100.64.0.20:443`, с `proxy_ssl_server_name on` и 404-заглушкой автонастройки до переключения.
Пошагово для Nginx Proxy Manager и пример для обычного nginx — [docs/reverse-proxy.md](docs/reverse-proxy.md).

**Проверки:**

```sh
curl -sI https://mail.example.com/ | head -1                       # 200 или 302
curl -s -o /dev/null -w '%{http_code}\n' https://autodiscover.example.com/autodiscover/autodiscover.xml   # 404 до переключения MX
sudo docker compose logs --since 5m nginx-mailcow | tail           # на бэкенде: внешний IP, не 100.64.0.10
```

### 4. MTA-STS

На время переезда — политика `mode: testing` с обоими MX (старого провайдера и новым), `max_age: 86400`.
Подробно — [docs/mta-sts.md](docs/mta-sts.md).

## Переключение

Момент переключения MX — смена записи MX домена: до него почта идёт к старому провайдеру, после — в mailcow.

### До переключения

- [ ] шаги 1–4 выполнены, проверки проходят;
- [ ] TTL записей MX, autodiscover/autoconfig снижен (например, до 300) не позже чем за сутки;
- [ ] SPF содержит `ip4:203.0.113.10`, DKIM-ключ mailcow опубликован, PTR шлюза = `mail.example.com`;
- [ ] MTA-STS: `testing`, оба MX;
- [ ] ящики перенесены в mailcow (imapsync или импорт — за рамками этого репозитория);
- [ ] порт 25 закрыт allowlist'ом, автонастройка клиентов отдаёт 404 — внешняя почта и клиенты
      не попадут в новый сервер раньше времени.

### Момент переключения MX

1. В `gateway.conf`: `SMTP_ALLOWLIST_ENABLED=no`, затем

   ```sh
   sudo gateway/install.sh --dry-run   # в diff исчезает строка reject ... smtp-allow.lst
   sudo gateway/install.sh
   ```
2. MX домена → `mail.example.com`.
3. В reverse proxy удалить строку с `return 404` для автонастройки (см. [docs/reverse-proxy.md](docs/reverse-proxy.md)).
4. DNS автонастройки: `autodiscover.` и `autoconfig.` (и SRV `_autodiscover._tcp`, если используется) →
   шлюз.
5. Проверки: `tools/check-relay.sh mail.example.com` с адреса, которого не было в allowlist;
   письмо с внешнего ящика доходит в mailcow; в логах mailcow — адрес отправляющего сервера.

### После переключения

- MTA-STS: когда старый MX выведен и прошло не меньше `max_age` старой политики — `mode: enforce`,
  только новый MX, новый `id` (см. [docs/mta-sts.md](docs/mta-sts.md));
- HSTS в reverse proxy;
- SPF: убрать старого провайдера;
- через несколько дней — проверить отчёты DMARC и TLS-RPT.

### Откат

- До переключения MX внешний мир о новом сервере не знает: достаточно остановить HAProxy (`systemctl disable --now haproxy`).
- После переключения MX — вернуть MX старому провайдеру (при коротком TTL это минуты). Письма, уже принятые
  mailcow, остаются в нём.
- Предыдущие версии файлов, изменённых скриптами, — в `/var/backups/mailcow-edge-gateway/<время>/`.

## Изменение настроек

Правьте `gateway.conf` / `backend.conf`, затем `--dry-run` и повторный запуск того же скрипта.
Файлы `/etc/haproxy/haproxy.cfg`, `/etc/mail-edge.nft`, `/etc/mailcow-edge.nft` целиком создаются
из шаблонов — ручные правки в них будут перезаписаны; меняйте шаблоны в `gateway/templates/` и
`backend/templates/`.

## Подводные камни

Кратко; подробности и объяснения — в [docs/design.md](docs/design.md#подводные-камни).

- **Клиенты mesh-VPN могут вставлять свои accept-правила** (`iifname <интерфейс оверлея> accept`)
  в начало цепочек input/forward nftables, включая чужие таблицы. Поэтому фильтр трафика оверлея стоит
  в `prerouting` (и `output`).
- **Docker-published порты не покрываются ACL оверлея**: политики доступа mesh-VPN их не защищают.
- **`"userland-proxy": false` в `/etc/docker/daemon.json` обязателен**: иначе IPv6-соединения через
  docker-proxy приходят в mailcow с `172.22.1.1` (входит в mynetworks) — open relay по IPv6.
  Дополнительно IPv6 на почтовые порты бэкенда — drop.
- **Dovecot**: адрес шлюза — в `haproxy_trusted_networks`, **не** в `login_trusted_networks`
  (иначе вход открытым паролем без TLS).
- **nginx mailcow**: только `set_real_ip_from`; второй `real_ip_header` (если он уже есть в `nginx -T`)
  ломает старт nginx.
- **Fail2ban mailcow**: шлюз в whitelist, иначе бан шлюза кладёт всю внешнюю почту.
- **Relay**: `myhostname` relay ≠ `myhostname` mailcow (иначе «loops back to myself»);
  `smtp_helo_name` = `mail.example.com` (совпадает с PTR); `inet_protocols = ipv4`, если у VPS нет
  PTR для IPv6; `disable_mime_output_conversion = yes` (не ломать DKIM).
- **Watchdog mailcow игнорирует relayhost** и ходит на 25 напрямую — из bridge mailcow наружу tcp/25
  закрыт, кроме адреса шлюза.
- **acme.sh по умолчанию использует ZeroSSL**: при CAA только для Let's Encrypt нужен
  `--server letsencrypt` (скрипт делает это сам).
- **Порт 25 до переключения — только allowlist**: mailcow уже принимает почту для своих доменов, и всё,
  что попадёт на шлюз до смены MX, осядет в новом сервере, а пользователи пока читают старый.

## Документация

- [docs/design.md](docs/design.md) — как устроено, модель угроз, почему так, подводные камни;
- [docs/reverse-proxy.md](docs/reverse-proxy.md) — Nginx Proxy Manager и обычный nginx для веба mailcow;
- [docs/certificate.md](docs/certificate.md) — сертификат mailcow через acme.sh и DNS-01;
- [docs/mta-sts.md](docs/mta-sts.md) — MTA-STS на время переезда и после;
- [docs/troubleshooting.md](docs/troubleshooting.md) — отладка: симптомы, причины, команды.
