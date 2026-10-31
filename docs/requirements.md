# Требования

Адреса в примерах: публичный адрес шлюза `203.0.113.10`, шлюз в оверлее `100.64.0.10`,
бэкенд (сервер mailcow) в оверлее `100.64.0.20`, интерфейс оверлея `wg0`, домен `example.com`.

## Шлюз (VPS)

- статический публичный IPv4, PTR которого можно выставить на `mail.example.com`;
- Linux с apt и debconf, systemd и nftables: пакеты haproxy, nftables и postfix скрипты ставят
  через apt;
- свободные порты 25, 465, 587, 143, 993, 995, 4190 (HAProxy) и 80/443 (reverse proxy);
- если на шлюзе есть свой firewall (ufw и т.п.) с запретом входящих по умолчанию — откройте в нём
  почтовые порты и 80/443; порт relay (2525) закрывает таблица `mail_edge` из этого репозитория.

## Бэкенд (сервер mailcow)

- mailcow-dockerized с поддержкой haproxy-listeners — в каталоге mailcow есть
  `helper-scripts/docker-compose.override.yml.d/HAPROXY/`;
- nftables (`nft`), systemd;
- python3 или jq — для правки `/etc/docker/daemon.json`;
- [acme.sh](https://github.com/acmesh-official/acme.sh) — для сертификата (см.
  [Сертификат mailcow](certificate.md)).

## Оверлейная сеть

- оба узла в одной сети (WireGuard или mesh-VPN) с постоянными адресами;
- между шлюзом и бэкендом разрешён трафик в обе стороны;
- маршрут по умолчанию через туннель не нужен (для WireGuard: `AllowedIPs` — только `/32` адрес
  соседа).

!!! warning "Если клиент оверлея сам правит nftables"
    Клиенты mesh-VPN могут вставлять свои accept-правила в начало цепочек input/forward — в том
    числе в чужие таблицы. Поэтому таблицы этого проекта фильтруют трафик в `prerouting` и `output`,
    см. [подводные камни](pitfalls.md#mesh-vpn).

## DNS и сертификат

- управление зоной почтового домена;
- для сертификата mailcow — DNS API, который поддерживает acme.sh (DNS-01): любой из
  [списка dnsapi](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).

## Рабочая машина (необязательно)

`--render` и `--dry-run` работают на Linux и macOS (bash 3.2+): конфиги можно отрендерить и
посмотреть до установки, без root.

```sh
git clone https://github.com/pugemon/mailcow-edge-gateway
cd mailcow-edge-gateway
make render          # render/gateway и render/backend из examples/*.conf
```
