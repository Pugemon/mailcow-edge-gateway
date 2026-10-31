# Пошаговая установка

Порядок: **сначала бэкенд, потом шлюз**, затем веб и MTA-STS. После каждого шага — проверки;
переходите к следующему, только когда они проходят. Вкладки над командами показывают, где их
выполнять.

До [переключения MX](cutover.md) внешняя почта продолжает идти к старому провайдеру: порт 25 шлюза
открыт только для тестовых адресов, автонастройка клиентов закрыта. Поэтому всё ниже можно делать
на работающем домене.

Адреса в примерах: публичный адрес шлюза `203.0.113.10`, шлюз в оверлее `100.64.0.10`,
бэкенд в оверлее `100.64.0.20`, интерфейс оверлея `wg0`, домен `example.com`.

## Шаг 0. Подготовка

1. Подключите шлюз и бэкенд к оверлейной сети и запишите их адреса и имя интерфейса
   (`ip -br addr`).
2. DNS (MX пока не трогать):
    - `A mail.example.com → 203.0.113.10`;
    - PTR `203.0.113.10 → mail.example.com` (в панели хостера VPS);
    - SPF: добавьте `ip4:203.0.113.10` к существующей записи, старого провайдера не убирайте.
3. Скопируйте репозиторий на оба узла:

    ```sh
    sudo git clone https://github.com/pugemon/mailcow-edge-gateway /opt/mailcow-edge-gateway
    ```

### Проверки после шага 0

=== "Шлюз"

    ```sh
    ping -c3 100.64.0.20                  # бэкенд отвечает по оверлею
    ip -br addr show wg0                  # 100.64.0.10 — это GATEWAY_OVERLAY_IP
    ```

=== "Бэкенд"

    ```sh
    ping -c3 100.64.0.10                  # шлюз отвечает по оверлею
    ip -br addr show wg0                  # 100.64.0.20 — это BACKEND_OVERLAY_IP
    ```

=== "Откуда угодно"

    ```sh
    dig +short A mail.example.com         # 203.0.113.10
    dig +short -x 203.0.113.10            # mail.example.com.
    dig +short TXT example.com | grep spf # ... ip4:203.0.113.10 ...
    ```

## Шаг 1. Бэкенд (сервер mailcow) {#backend}

### Настройки и установка

```sh
cd /opt/mailcow-edge-gateway
sudo cp examples/backend.conf backend.conf
sudo $EDITOR backend.conf           # адреса, OVERLAY_IFACE, MAILCOW_DIR, SERVICES, ACME_DNS_API

sudo backend/install.sh --dry-run   # план: diff всех файлов, ничего не меняется
sudo backend/install.sh             # тот же план, вопрос «Применить?», установка
```

Описание всех параметров — в [Конфигурации](configuration.md#backend-conf). Скрипт меняет только
файлы и загружает таблицу nftables; Docker и контейнеры mailcow он не перезапускает — команды для
этого печатает в конце:

```sh
sudo systemctl restart docker       # если менялся /etc/docker/daemon.json (userland-proxy=false);
                                    # перезапустит все контейнеры на хосте
cd /opt/mailcow-dockerized
sudo docker compose up -d           # опубликовать PROXY-порты на 100.64.0.20
```

!!! note "Свой docker-compose.override.yml"
    Если `docker-compose.override.yml` у вас уже был, скрипт остановится и попросит слить его с
    `helper-scripts/docker-compose.override.yml.d/HAPROXY/docker-compose.override.yml` вручную
    (секции `ports` у `postfix-mailcow` и `dovecot-mailcow`), а затем запустить его снова.

### Whitelist шлюза в Fail2ban mailcow

В интерфейсе администратора mailcow, в параметрах Fail2ban (Netfilter), добавьте `100.64.0.10/32`
в список разрешённых сетей. Иначе однажды Netfilter забанит адрес шлюза (например, за ошибки
авторизации, пришедшие через веб), и вместе с ним отвалится вся внешняя почта и веб.

### Сертификат

DNS-01 через acme.sh; подробно — [Сертификат mailcow](certificate.md).

```sh
# acme.sh установлен, переменные DNS API экспортированы
sudo backend/issue-cert.sh --staging      # тестовый выпуск: DNS API, CAA, пропагация
sudo backend/issue-cert.sh --production   # боевой выпуск, установка в mailcow, cron продления
```

### Проверки после шага 1 {#backend-checks}

=== "Бэкенд"

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

    # контейнер вне сети mailcow не достаёт до PROXY-портов: ожидается таймаут
    sudo docker run --rm alpine nc -zv -w5 100.64.0.20 10025
    ```

=== "Другой узел оверлея или LAN"

    ```sh
    nc -zv -w5 100.64.0.20 10025      # ожидается таймаут: в prerouting только drop
    ```

    Барьер 1 из [модели угроз](threat-model.md): к PROXY-портам mailcow пускают только шлюз.

## Шаг 2. Шлюз (VPS) {#gateway}

### Настройки и установка

```sh
cd /opt/mailcow-edge-gateway
sudo cp examples/gateway.conf gateway.conf
sudo $EDITOR gateway.conf           # адреса, OVERLAY_IFACE, MAIL_HOSTNAME, RELAY_HOSTNAME, SMTP_ALLOWLIST

sudo gateway/install.sh --dry-run   # diff конфигов HAProxy/nftables и параметров Postfix
sudo gateway/install.sh             # пакеты, nftables mail_edge, HAProxy, relay Postfix
```

В `SMTP_ALLOWLIST` добавьте внешний адрес офиса и адреса машин, с которых будете тестировать порт 25;
публичный адрес самого шлюза добавляется автоматически. Описание всех параметров —
в [Конфигурации](configuration.md#gateway-conf).

Конфиги можно посмотреть и до установки, на рабочей машине: `gateway/install.sh -c gateway.conf
--render /tmp/gw` (root не нужен).

### Проверки после шага 2 {#gateway-checks}

=== "Шлюз"

    ```sh
    sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # Configuration file is valid
    sudo ss -ltnp | grep haproxy                  # 203.0.113.10:25 465 587 143 993 995 4190
    sudo ss -ltnp | grep ':2525'                  # master (postfix)
    sudo nft list table inet mail_edge

    # барьер 2: никто, кроме пользователя haproxy, не подключится к PROXY-порту бэкенда
    sudo -u nobody bash -c 'exec 3<>/dev/tcp/100.64.0.20/10025'   # Connection refused
    sudo bash -c 'exec 3<>/dev/tcp/100.64.0.20/10025'             # root тоже: Connection refused
    ```

=== "Снаружи"

    С машины из `SMTP_ALLOWLIST` (или с самого шлюза):

    ```sh
    tools/check-tls.sh mail.example.com     # на всех портах OK
    tools/check-relay.sh mail.example.com   # OK  relay запрещён (554 Relay access denied)
    nc -zv -w5 203.0.113.10 2525            # relay снаружи недоступен: таймаут
    ```

=== "Бэкенд"

    Реальный адрес клиента виден в логах mailcow — там должен быть адрес вашей внешней машины,
    а не `100.64.0.10`:

    ```sh
    cd /opt/mailcow-dockerized
    sudo docker compose logs --since 10m postfix-mailcow | grep -E 'CONNECT from|connect from'
    sudo docker compose logs --since 10m dovecot-mailcow | grep 'rip='
    ```

    Исходящая почта: отправьте письмо из SOGo на внешний ящик или так:

    ```sh
    printf 'Subject: relay test\n\ntest\n' |
      sudo docker compose exec -T postfix-mailcow sendmail -f postmaster@example.com you@example.net
    ```

На шлюзе письмо проходит через relay, у получателя в заголовках — `spf=pass` (203.0.113.10)
и `dkim=pass`:

```sh
sudo journalctl --since '10 min ago' | grep -E 'postfix/(from-mailcow/smtpd|smtp)\['   # status=sent
```

## Шаг 3. Веб: reverse proxy {#web}

Один proxy host на все веб-имена (`mail.`, `autodiscover.`, `autoconfig.`, `mta-sts.` каждого домена)
→ `https://100.64.0.20:443`, с `proxy_ssl_server_name on` и 404-заглушкой автонастройки до
переключения MX. Пошагово для Nginx Proxy Manager и пример для обычного nginx —
[Reverse proxy](reverse-proxy.md).

### Проверки после шага 3

=== "Снаружи"

    ```sh
    curl -sI https://mail.example.com/ | head -1      # 200 или 302
    curl -s -o /dev/null -w '%{http_code}\n' \
      https://autodiscover.example.com/autodiscover/autodiscover.xml   # 404 до переключения MX
    ```

=== "Бэкенд"

    ```sh
    cd /opt/mailcow-dockerized
    sudo docker compose logs --since 5m nginx-mailcow | tail   # внешние адреса, не 100.64.0.10
    ```

## Шаг 4. MTA-STS {#mta-sts}

На время переезда — политика `mode: testing` с обоими MX (старого провайдера и новым),
`max_age: 86400`. Подробно — [MTA-STS](mta-sts.md).

### Проверки после шага 4

```sh
curl -s https://mta-sts.example.com/.well-known/mta-sts.txt   # mode: testing, оба mx
dig +short TXT _mta-sts.example.com                           # "v=STSv1; id=..."
```

## Дальше

Всё проверено — переходите к [чек-листу переключения MX](cutover.md).

Повторный запуск любого установочного скрипта с теми же настройками ничего не меняет, поэтому его
можно использовать и как проверку: «файлов к изменению: 0» в `--dry-run` значит, что система
соответствует настройкам.
