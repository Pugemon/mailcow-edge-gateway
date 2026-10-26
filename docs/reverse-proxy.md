# Веб mailcow через reverse proxy на шлюзе

Почтовые порты идут через HAProxy, а HTTP(S) — через обычный reverse proxy на том же шлюзе. В примерах —
Nginx Proxy Manager (NPM); для обычного nginx есть готовый файл `examples/nginx-reverse-proxy.conf`.

## Что проксируется

Один proxy host на все веб-имена почты → `https://100.64.0.20:443` (бэкенд в оверлее, порт
`MAILCOW_HTTPS_PORT`):

| Имя                        | Зачем                                                  |
|----------------------------|--------------------------------------------------------|
| `mail.example.com`         | SOGo, админка mailcow, ActiveSync, EAS/DAV             |
| `autodiscover.<домен>`     | автонастройка Outlook и мобильных клиентов (каждый почтовый домен) |
| `autoconfig.<домен>`       | автонастройка Thunderbird и др. (каждый почтовый домен) |
| `mta-sts.<домен>`          | политика MTA-STS (каждый почтовый домен)               |

Сертификат для этих имён выпускает сам reverse proxy (HTTP-01 — если все имена уже указывают на шлюз,
иначе DNS-01). Он не связан с сертификатом mailcow на почтовых портах (`docs/certificate.md`).

## Nginx Proxy Manager

**Hosts → Proxy Hosts → Add Proxy Host.**

Вкладка **Details**:

| Поле                   | Значение                                                       |
|------------------------|----------------------------------------------------------------|
| Domain Names           | все имена из таблицы выше (каждое — отдельно, Enter)           |
| Scheme                 | `https`                                                        |
| Forward Hostname / IP  | `100.64.0.20`                                                  |
| Forward Port           | `443`                                                          |
| Cache Assets           | выкл                                                           |
| Block Common Exploits  | **выкл** — ломает SOGo и ActiveSync                            |
| Websockets Support     | вкл                                                            |
| Access List            | Publicly Accessible                                            |

Вкладка **Custom Locations** — ничего не добавлять.

Вкладка **SSL**:

| Поле                      | Значение                                                   |
|---------------------------|------------------------------------------------------------|
| SSL Certificate           | Request a new SSL Certificate                              |
| Force SSL                 | вкл                                                        |
| HTTP/2 Support            | вкл                                                        |
| HSTS Enabled              | выкл до переключения (включить после)                      |
| Use a DNS Challenge       | выкл, если все имена уже указывают на шлюз; иначе вкл      |
| Email Address for Let's Encrypt | рабочий адрес администратора                         |

Вкладка **Advanced → Custom Nginx Configuration** — содержимое `examples/npm-advanced.conf` целиком:

```nginx
proxy_ssl_server_name on;
proxy_ssl_name $host;
client_max_body_size 0;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
proxy_buffer_size 128k;
proxy_buffers 64 512k;
proxy_busy_buffers_size 512k;

# ДО ПЕРЕКЛЮЧЕНИЯ MX: автонастройка клиентов закрыта. При переключении MX удалить эту строку.
location ~* ^/(autodiscover/|mail/config-v1\.1\.xml|\.well-known/autoconfig/|Microsoft-Server-ActiveSync) { return 404; }
```

**Save** — NPM выпустит сертификат на все имена.

Замечания:

- **Не используйте Streams NPM для почтовых портов.** Stream не передаёт адрес клиента (mailcow увидит
  все соединения с адреса шлюза) и займёт те же порты, что HAProxy. Если streams на 25/465/587/143/993/
  110/995/4190 остались с прошлых настроек — удалите их.
- Админку NPM (порт 81) не публикуйте в интернет: доступ через оверлей или SSH-туннель.
- NPM работает в Docker, его контейнер не может подключиться к PROXY-портам бэкенда (таблица
  `mail_edge` на шлюзе) — ему это и не нужно: он ходит только на 443.

## Обычный nginx

`examples/nginx-reverse-proxy.conf` — то же самое для nginx на шлюзе: редирект с 80 на 443 (кроме
`/.well-known/acme-challenge/`), заглушка автонастройки, проксирование на бэкенд с SNI, заголовками
`X-Forwarded-*`, websocket и большими буферами/таймаутами. Подставьте свои имена, путь к сертификату
и адрес бэкенда.

## Параметры и зачем они

- `proxy_ssl_server_name on; proxy_ssl_name $host;` — nginx mailcow выбирает виртуальный хост по SNI.
  Без SNI запросы к `autodiscover.`, `autoconfig.`, `mta-sts.` попадают в сервер по умолчанию.
  Проверку сертификата бэкенда NPM по умолчанию не делает, поэтому сертификату mailcow не нужны веб-имена.
- `client_max_body_size 0` — вложения в SOGo, импорт.
- `proxy_read_timeout` / `proxy_send_timeout 3600s` — долгие запросы ActiveSync (Ping) и DAV.
- `proxy_buffer_size`, `proxy_buffers`, `proxy_busy_buffers_size` — большие заголовки и ответы SOGo/EAS.

## Реальный IP клиентов в mailcow

Reverse proxy передаёт адрес клиента в `X-Forwarded-For`. nginx mailcow уже настроен брать адрес из
этого заголовка (`real_ip_header X-Forwarded-For; real_ip_recursive on;`), но доверяет только частным
сетям. `backend/install.sh` добавляет `set_real_ip_from 100.64.0.10/32;` в
`data/conf/nginx/site.real-ip-gateway.custom`. Подделать адрес клиент не может: при
`real_ip_recursive on` берётся крайний правый недоверенный адрес — тот, что дописал reverse proxy.

Проверка (на бэкенде): `docker compose logs --since 5m nginx-mailcow` — в логе внешние адреса,
а не `100.64.0.10`.

## Заглушка автонастройки до переключения

Пока MX смотрит на старого провайдера, новые Outlook, Thunderbird и телефоны не должны находить новый
сервер через autodiscover/autoconfig — иначе пользователи настроятся на пустые ящики. Заглушка
возвращает 404 на:

- `/autodiscover/...` (Outlook, мобильные клиенты; регистр не важен — `~*`);
- `/mail/config-v1.1.xml` и `/.well-known/autoconfig/...` (Thunderbird и др.);
- `/Microsoft-Server-ActiveSync` (ActiveSync).

Это важно, если имена `autodiscover.`/`autoconfig.` уже указывают на шлюз (например, чтобы NPM выпустил
сертификат по HTTP-01). Проверить ActiveSync до переключения можно из офисной сети напрямую на бэкенд.

## При переключении и после

- В момент переключения MX: удалить строку `location ~* ^/(autodiscover/|…) { return 404; }` → Save (или `nginx -s reload`).
- После переключения, когда всё работает: включить HSTS.

## Проверки

```sh
curl -sI https://mail.example.com/ | head -1                      # 200 или 302
curl -s -o /dev/null -w '%{http_code}\n' https://autodiscover.example.com/autodiscover/autodiscover.xml
#   до переключения MX: 404; после: 401/200 (ответ mailcow)
curl -s https://mta-sts.example.com/.well-known/mta-sts.txt        # политика MTA-STS
```
