# Сертификат mailcow: acme.sh и DNS-01

Сертификат на почтовых портах (25, 465, 587, 143, 993, 995, 4190) предъявляет сам mailcow — HAProxy
в mode tcp его не трогает. Выпускает его acme.sh на бэкенде через DNS-01; встроенный ACME mailcow
выключен (`SKIP_LETS_ENCRYPT=y`).

## Почему DNS-01

- HTTP-01 для `mail.example.com` приходит на шлюз, где порт 80 занят reverse proxy — он сам
  обслуживает `/.well-known/acme-challenge/` для своих сертификатов, до mailcow запрос не доходит.
- DNS-01 не зависит от того, куда указывают A-записи и кто держит порт 80: сертификат можно получить
  до переключения, и продление не ломается при смене reverse proxy.
- Бэкенду не нужен ни один входящий порт из интернета.

## Какие имена

`MAIL_HOSTNAME` (`mail.example.com`) — имя, по которому клиенты и серверы подключаются к почтовым
портам. Веб-имена (`autodiscover.`, `autoconfig.`, `mta-sts.`) обслуживает сертификат reverse proxy,
добавлять их сюда не нужно. Если клиенты подключаются к почте по другим именам — перечислите их
в `CERT_EXTRA_NAMES`.

## Установка acme.sh

От root на бэкенде:

```sh
git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /root/acme.sh-src
cd /root/acme.sh-src && ./acme.sh --install -m admin@example.com   # ставится в /root/.acme.sh
```

Каталог установки — `ACME_HOME` в `backend.conf` (по умолчанию `/root/.acme.sh`).

## Креды DNS API

Подходит любой DNS API, который поддерживает acme.sh: его имя вида `dns_xxx` задаётся
в `ACME_DNS_API`. Список провайдеров и переменных с кредами для каждого из них — в
[wiki acme.sh, раздел dnsapi](https://github.com/acmesh-official/acme.sh/wiki/dnsapi); сверяйте имена
переменных с версией acme.sh, которая у вас установлена.

Перед первым выпуском экспортируйте переменные своего провайдера (имена ниже — условные):

```sh
# пробел в начале строки — команда не попадёт в историю (HISTCONTROL=ignorespace)
 export XXX_User='<логин или ID аккаунта>'
 read -rs XXX_Token && export XXX_Token   # секрет вводится без отображения
```

После первого успешного выпуска acme.sh сохраняет креды в `$ACME_HOME/account.conf` (`SAVED_...`)
и дальше берёт их оттуда — переменные окружения больше не нужны. `issue-cert.sh` выставляет файлу
права `600`; каталог `ACME_HOME` должен быть доступен только root. Права пользователя DNS API
ограничьте зоной почтового домена, если провайдер это позволяет.

## Выпуск

```sh
sudo backend/issue-cert.sh --staging      # тестовый CA: проверка DNS API, CAA и пропагации
sudo backend/issue-cert.sh --production   # боевой выпуск и установка
```

`--staging` выпускает сертификат через `letsencrypt_test` и никуда его не ставит: ошибки в кредах,
CAA или задержке DNS не расходуют лимиты боевого Let's Encrypt.

`--production`:

1. `acme.sh --set-default-ca --server letsencrypt` — CA по умолчанию у acme.sh — ZeroSSL; если в CAA
   домена разрешён только Let's Encrypt (`0 issue "letsencrypt.org"`), выпуск через ZeroSSL не пройдёт;
2. `acme.sh --issue --server letsencrypt --dns <ACME_DNS_API> -d mail.example.com --keylength 2048`
   (`--force`, если до этого был тестовый выпуск: acme.sh считает тестовый сертификат действующим);
   если боевой сертификат уже есть — выпуск пропускается (перевыпуск — `--force`);
3. `acme.sh --install-cert ... --key-file data/assets/ssl/key.pem --fullchain-file data/assets/ssl/cert.pem
   --reloadcmd /usr/local/sbin/mailcow-cert-reload.sh` — копирует сертификат в mailcow и запоминает
   пути для продлений;
4. `acme.sh --install-cronjob` — ежедневная проверка продления.

`--install-only` повторяет шаги 3–4 без выпуска (например, после переустановки mailcow).
`--dry-run` печатает команды acme.sh, ничего не выполняя.

## Перезагрузка сервисов

`/usr/local/sbin/mailcow-cert-reload.sh` (ставит `backend/install.sh`) вызывается acme.sh после каждого
выпуска и продления:

```sh
docker compose exec -T postfix-mailcow postfix reload &&
  docker compose exec -T dovecot-mailcow doveadm reload &&
  docker compose exec -T nginx-mailcow nginx -s reload ||
  docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow
```

При `SKIP_LETS_ENCRYPT=y` mailcow сам замену файлов сертификата не отслеживает — без хука Postfix,
Dovecot и nginx продолжали бы отдавать старый сертификат до перезапуска.

## Тип ключа

`ACME_KEYLENGTH=2048` (RSA) — как у встроенного ACME mailcow, максимальная совместимость со старыми
почтовыми клиентами и серверами. `ec-256`/`ec-384` тоже работают с Postfix, Dovecot и nginx; для них
acme.sh хранит сертификат в каталоге `<имя>_ecc`, скрипт это учитывает.

## Проверки

```sh
openssl x509 -in /opt/mailcow-dockerized/data/assets/ssl/cert.pem -noout -subject -issuer -enddate
/root/.acme.sh/acme.sh --list                 # сертификат, CA, дата продления
crontab -l | grep acme.sh                      # cron продления
tools/check-tls.sh mail.example.com            # снаружи: все порты, Verify return code: 0
```

Проверить продление целиком (выпуск + хук), не дожидаясь срока:
`/root/.acme.sh/acme.sh --renew -d mail.example.com --force` — это настоящий боевой выпуск,
учитывается в лимитах Let's Encrypt; не делайте это часто.
