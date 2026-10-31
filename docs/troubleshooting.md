# Отладка

## Куда смотреть

=== "Шлюз"

    ```sh
    sudo journalctl -u haproxy --since '15 min ago'          # или /var/log/haproxy.log (rsyslog)
    echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,5,8,18   # сессии, статус
    sudo nft list table inet mail_edge                       # счётчики drop/reject растут — кто-то стучится
    sudo ss -tnp | grep -E ':(10025|10465|10587|10143|10993|10110|10995|14190)\b'   # соединения HAProxy к бэкенду
    sudo journalctl --since '15 min ago' | grep -E 'postfix/(from-mailcow/smtpd|smtp)\['   # relay
    sudo postqueue -p                                        # очередь relay
    sudo tcpdump -ni wg0 host 100.64.0.20 and port 10025     # трафик к бэкенду по оверлею
    ```

=== "Бэкенд"

    В каталоге mailcow:

    ```sh
    sudo nft list table inet mailcow_edge
    sudo docker compose logs --since 15m postfix-mailcow dovecot-mailcow nginx-mailcow netfilter-mailcow
    sudo docker compose exec postfix-mailcow postqueue -p    # очередь mailcow (ждёт relay?)
    sudo docker compose exec postfix-mailcow postconf relayhost
    sudo docker compose config | grep -A3 'host_ip: 100.64.0.20'
    sudo tcpdump -ni wg0 port 10025 or port 2525
    ```

=== "Снаружи"

    ```sh
    tools/check-tls.sh mail.example.com     # TLS и сертификат на всех почтовых портах
    tools/check-relay.sh mail.example.com   # open relay: OK / WARN / FAIL
    ```

## Симптомы

**В логах mailcow адрес шлюза (`100.64.0.10`) вместо адреса клиента.**
Соединение пришло не на haproxy-listener: HAProxy указывает на 25 вместо 10025, порты из
`docker-compose.override.yml` не опубликованы (`docker compose config`), почтовые порты идут через
Streams NPM или DNAT, а не через HAProxy.

**Postfix: `haproxy read: …`, `lost connection after CONNECT`; Dovecot: `haproxy: …` ошибки.**
Несовпадение PROXY / не-PROXY: на PROXY-порт пришло соединение без заголовка (health check, ручной
`nc`, другой прокси) или HAProxy шлёт заголовок на обычный порт. Сверьте порты в `haproxy.cfg` и
[таблицу портов](configuration.md#ports).

**Dovecot: `haproxy: Client not trusted`.**
Адрес, с которого Dovecot видит соединение, не входит в `haproxy_trusted_networks`. Причины: в
`extra.conf` другой адрес шлюза; работает docker-proxy (`userland-proxy` не выключен или Docker не
перезапущен) — тогда источник `172.22.1.1`.

**Соединения к 25 со стороны отклоняются сразу после подключения.**
До переключения так и должно быть — адреса нет в `smtp-allow.lst`. После переключения MX — проверьте, что
`SMTP_ALLOWLIST_ENABLED=no` и `gateway/install.sh` перезапущен (в `haproxy.cfg` нет строки
`reject if !{ src -f /etc/haproxy/smtp-allow.lst }`). Источник в `deny-src.lst` (частная сеть) тоже
отклоняется — тестируйте с внешнего адреса.

**Таймаут при подключении к PROXY-портам бэкенда.**
Так работает барьер 1 для всех, кроме шлюза. Если таймаут у самого HAProxy: адрес шлюза в оверлее
изменился (сверьте `GATEWAY_OVERLAY_IP` с `ip -4 addr show wg0`), имя интерфейса оверлея не совпадает с `OVERLAY_IFACE`
(`OVERLAY_IFACE`), оверлей не поднят.

**`Connection refused` при подключении со шлюза к PROXY-портам бэкенда.**
Если это не HAProxy — так и задумано (барьер 2). Если HAProxy: проверьте, что его процессы работают
от пользователя `haproxy` (`ps -o user,cmd -C haproxy`).

**`nft -f /etc/mail-edge.nft`: ошибка на `meta skuid "haproxy"`.**
Пользователя `haproxy` нет — установите пакет haproxy (`gateway/install.sh` делает это сам).

**Внешняя почта и веб пропали целиком, на шлюзе всё работает.**
Netfilter mailcow забанил адрес шлюза: `docker compose logs netfilter-mailcow | grep 100.64.0.10`.
Снимите бан в интерфейсе mailcow и добавьте `100.64.0.10/32` в whitelist Fail2ban.

**Исходящие письма возвращаются с `mail for … loops back to myself`.**
`myhostname` relay совпадает с `myhostname` mailcow. `RELAY_HOSTNAME` ≠ `MAIL_HOSTNAME`, повторить
`gateway/setup-relay.sh`.

**Исходящие застряли в очереди mailcow: `connect to 100.64.0.10[100.64.0.10]:2525: Connection timed out`.**
Relay не настроен или недоступен: `ss -ltn | grep 2525` на шлюзе, оверлей, адрес бэкенда
в `mynetworks` relay (`postconf mynetworks`). Сообщение `Client host rejected` от relay — бэкенд
приходит с другого адреса (не `BACKEND_OVERLAY_IP`).

**Получатели отклоняют письма: PTR, HELO, SPF.**
- PTR `203.0.113.10` ≠ `mail.example.com` или A-запись не совпадает;
- письмо ушло по IPv6 без PTR — `RELAY_INET_PROTOCOLS=ipv4`;
- в SPF нет `ip4:203.0.113.10`;
- письмо ушло мимо relay с офисного адреса — проверьте `relayhost` в mailcow и счётчики правила
  `tcp dport 25 … reject` в `nft list table inet mailcow_edge`.

**У получателя `dkim=fail (body hash did not verify)`.**
Relay перекодировал тело: `postconf disable_mime_output_conversion` на шлюзе должно быть `yes`.

**nginx mailcow не стартует после `backend/install.sh`: `"real_ip_header" directive is duplicate`.**
В `data/conf/nginx/site.real-ip-gateway.custom` есть `real_ip_header`, а конфигурация mailcow уже
задаёт его. Оставьте в файле только `set_real_ip_from`, `docker compose restart nginx-mailcow`.

**В логах nginx mailcow адрес шлюза вместо клиента.**
Нет `set_real_ip_from 100.64.0.10/32` (файл не подхватился — перезапустите nginx-mailcow) или reverse
proxy не передаёт `X-Forwarded-For`.

**`autodiscover` / автонастройка не работает.**
До переключения MX — 404 от заглушки, так и задумано. После — заглушка не удалена, нет `proxy_ssl_server_name on`
(запрос попадает в сервер mailcow по умолчанию), DNS `autodiscover.`/`autoconfig.` не указывает на шлюз.

**Контейнеры postfix/dovecot mailcow не стартуют: `cannot assign requested address` для 100.64.0.20.**
Интерфейс оверлея ещё не поднят и не включён `net.ipv4.ip_nonlocal_bind` —
`sysctl net.ipv4.ip_nonlocal_bind` должно быть `1`.

**После `systemctl restart nftables` всё сломалось.**
`/etc/nftables.conf` начинается с `flush ruleset` и стирает правила Docker и таблицы этого репозитория.
Бэкенд: `systemctl restart docker mailcow-edge`; шлюз: `systemctl restart mail-edge docker`.

**Крупные письма зависают, мелкие проходят.**
MTU оверлея: проверьте `ip link show wg0`, прохождение ICMP «fragmentation needed» и при необходимости
уменьшите MTU интерфейса оверлея.

**`tools/check-tls.sh`: `Verify return code: 62` (hostname mismatch).**
В сертификате нет имени, по которому идёт подключение: `MAIL_HOSTNAME`/`CERT_EXTRA_NAMES` и
`openssl x509 -in data/assets/ssl/cert.pem -noout -ext subjectAltName`. Код `20`/`21` — неполная
цепочка: в `cert.pem` должен лежать fullchain (`--fullchain-file`).
