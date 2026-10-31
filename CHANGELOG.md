# Изменения

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [0.1.0] — 2026-10-31

Первый выпуск.

### Добавлено

- `gateway/install.sh`: HAProxy в mode tcp с PROXY protocol v2 к haproxy-listeners mailcow,
  таблица nftables `inet mail_edge` (к PROXY-портам бэкенда — только пользователь `haproxy`,
  порт relay закрыт снаружи), отказ источникам из частных и служебных сетей, allowlist порта 25
  до переключения MX.
- `gateway/setup-relay.sh`: Postfix на шлюзе как relay исходящей почты mailcow.
- `backend/install.sh`: таблица nftables `inet mailcow_edge` (к PROXY-портам — только шлюз,
  IPv6 на почтовые порты — drop, tcp/25 из контейнеров — только на шлюз), `ip_nonlocal_bind`,
  `mailcow.conf` и `docker-compose.override.yml` для haproxy-listeners, Dovecot
  `haproxy_trusted_networks`, nginx `set_real_ip_from`, `relayhost`, `"userland-proxy": false`.
- `backend/issue-cert.sh`: сертификат mailcow через acme.sh и DNS-01 (тестовый и боевой выпуск,
  установка, cron продления, хук перезагрузки сервисов).
- `tools/check-tls.sh` и `tools/check-relay.sh`: проверки TLS на почтовых портах и open relay.
- Общие флаги установочных скриптов: `--dry-run` (план и diff), `--render DIR` (готовые файлы
  без root), `-y/--yes` (без вопроса), `--version`; подтверждение перед изменениями, итог
  установки со списком следующих шагов и проверок.
- Цветной вывод OK/WARN/FAIL только в терминале и без `NO_COLOR`; документированные коды возврата.
- Тесты рендера шаблонов и библиотеки, проверка `haproxy -c` и `nft -c` в CI.
- Сайт документации: схема трафика, модель угроз, пошаговая установка с проверками, чек-лист
  переключения MX, конфигурация, справочник команд, отладка.

[0.1.0]: https://github.com/pugemon/mailcow-edge-gateway/releases/tag/v0.1.0
