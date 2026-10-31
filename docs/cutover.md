# Переключение MX

Момент переключения MX — смена записи MX домена: до него почта идёт к старому провайдеру, после —
в mailcow через шлюз. До этого момента новый сервер для внешнего мира закрыт: порт 25 шлюза
принимает только адреса из `SMTP_ALLOWLIST`, автонастройка клиентов отдаёт 404.

## До переключения

Отмечайте по мере выполнения:

- [ ] шаги 1–4 [установки](install.md) выполнены, проверки после каждого шага проходят;
- [ ] `tools/check-tls.sh mail.example.com` — на всех портах OK;
- [ ] `tools/check-relay.sh mail.example.com` — OK, relay запрещён;
- [ ] тестовое письмо из mailcow наружу дошло, у получателя `spf=pass` и `dkim=pass`;
- [ ] TTL записей MX, `autodiscover`/`autoconfig` снижен (например, до 300) не позже чем за сутки;
- [ ] SPF содержит `ip4:203.0.113.10`, DKIM-ключ mailcow опубликован, PTR шлюза = `mail.example.com`;
- [ ] MTA-STS: `mode: testing`, оба MX; если у старого провайдера была политика `enforce` — с момента
      публикации новой прошло не меньше её `max_age` (см. [MTA-STS](mta-sts.md));
- [ ] ящики перенесены в mailcow (imapsync, sync jobs mailcow или импорт — например,
      [mailcow-migration-tools](https://github.com/pugemon/mailcow-migration-tools));
- [ ] Fail2ban mailcow: адрес шлюза в whitelist;
- [ ] пользователи предупреждены, новые настройки клиентов подготовлены.

## Момент переключения MX

1. Откройте порт 25 для всех: в `gateway.conf` — `SMTP_ALLOWLIST_ENABLED=no`, затем

    ```sh
    sudo gateway/install.sh --dry-run   # в diff исчезает строка reject ... smtp-allow.lst
    sudo gateway/install.sh
    ```

2. Смените MX домена на `mail.example.com`.
3. В reverse proxy удалите строку с `return 404` для автонастройки
   (см. [Reverse proxy](reverse-proxy.md#autoconfig-stub)).
4. DNS автонастройки: `autodiscover.` и `autoconfig.` (и SRV `_autodiscover._tcp`, если
   используется) → шлюз.

## Проверки сразу после

=== "Снаружи"

    С адреса, которого **не было** в `SMTP_ALLOWLIST`:

    ```sh
    tools/check-relay.sh mail.example.com   # OK: порт 25 открыт, relay запрещён
    dig +short MX example.com               # mail.example.com (с учётом TTL)
    curl -s -o /dev/null -w '%{http_code}\n' \
      https://autodiscover.example.com/autodiscover/autodiscover.xml   # 401 или 200, не 404
    ```

=== "Бэкенд"

    Письмо с внешнего ящика доходит в mailcow; в логе — адрес отправляющего сервера, а не шлюза:

    ```sh
    cd /opt/mailcow-dockerized
    sudo docker compose logs --since 15m postfix-mailcow | grep -E 'CONNECT from|connect from'
    ```

=== "Шлюз"

    ```sh
    sudo grep -c smtp-allow /etc/haproxy/haproxy.cfg   # 0
    sudo journalctl -u haproxy --since '15 min ago' | tail
    ```

## После переключения

- [ ] MTA-STS: когда старый MX выведен и прошло не меньше `max_age` политики — `mode: enforce`,
      только новый MX, новый `id` (см. [MTA-STS](mta-sts.md#enforce));
- [ ] HSTS в reverse proxy;
- [ ] SPF: убрать старого провайдера;
- [ ] через несколько дней — проверить отчёты DMARC и TLS-RPT;
- [ ] TTL записей вернуть к обычным значениям.

## Откат

- **До переключения MX** внешний мир о новом сервере не знает: достаточно остановить HAProxy
  (`sudo systemctl disable --now haproxy`).
- **После переключения MX** — вернуть MX старому провайдеру (при коротком TTL это минуты). Письма,
  уже принятые mailcow, остаются в нём. Порт 25 можно снова закрыть allowlist'ом:
  `SMTP_ALLOWLIST_ENABLED=yes` и `sudo gateway/install.sh`.
- Предыдущие версии файлов, изменённых скриптами, — в `/var/backups/mailcow-edge-gateway/<время>/`.
