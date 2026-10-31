# Быстрый старт

Вся установка одним списком — для тех, кто уже прочитал [требования](requirements.md). Подробности
и проверки после каждого шага — в [пошаговой установке](install.md).

Перед началом: оба узла в оверлейной сети, `A mail.example.com` и PTR публичного адреса шлюза
указывают друг на друга, публичный адрес шлюза добавлен в SPF. MX пока не трогаем.

=== "1. Бэкенд"

    ```sh
    sudo git clone https://github.com/pugemon/mailcow-edge-gateway /opt/mailcow-edge-gateway
    cd /opt/mailcow-edge-gateway
    sudo cp examples/backend.conf backend.conf && sudo $EDITOR backend.conf

    sudo backend/install.sh --dry-run          # план
    sudo backend/install.sh                    # установка (с подтверждением)
    sudo systemctl restart docker              # если менялся daemon.json
    (cd /opt/mailcow-dockerized && sudo docker compose up -d)

    sudo backend/issue-cert.sh --staging       # проверить DNS API
    sudo backend/issue-cert.sh --production    # сертификат в mailcow
    ```

    В интерфейсе mailcow добавьте адрес шлюза в оверлее в whitelist Fail2ban.

=== "2. Шлюз"

    ```sh
    sudo git clone https://github.com/pugemon/mailcow-edge-gateway /opt/mailcow-edge-gateway
    cd /opt/mailcow-edge-gateway
    sudo cp examples/gateway.conf gateway.conf && sudo $EDITOR gateway.conf

    sudo gateway/install.sh --dry-run          # план
    sudo gateway/install.sh                    # HAProxy, nftables, relay (с подтверждением)
    ```

    Reverse proxy для веба — по [инструкции](reverse-proxy.md).

=== "3. Проверка снаружи"

    С адреса из `SMTP_ALLOWLIST`:

    ```sh
    tools/check-tls.sh mail.example.com        # на всех портах OK
    tools/check-relay.sh mail.example.com      # OK  relay запрещён
    ```

Пример итога `gateway/install.sh`:

```text
==> Итог
    OK    таблица nftables inet mail_edge загружена
    OK    HAProxy работает: порты 25 465 587 143 993 995 4190 на 203.0.113.10
    OK    relay Postfix слушает порт 2525 (принимает только от 100.64.0.20)
    файлов изменено: 6
    порт 25 открыт только для адресов из smtp-allow.lst (до переключения MX)

==> Что проверить дальше
    На шлюзе:
      sudo ss -ltnp | grep haproxy                 # порты на 203.0.113.10
      sudo nft list table inet mail_edge           # счётчики drop/reject
      sudo -u nobody bash -c 'exec 3<>/dev/tcp/100.64.0.20/10025'   # ожидается Connection refused
    С внешней машины из SMTP_ALLOWLIST (или с самого шлюза):
      tools/check-tls.sh mail.example.com            # на всех портах OK
      tools/check-relay.sh mail.example.com          # OK: relay запрещён
    ...
```

Когда всё работает — [чек-лист переключения MX](cutover.md).
