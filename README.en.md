# mailcow-edge-gateway

[Русский](README.md)

Publish a [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) server that sits behind
NAT through an external VPS: HAProxy with PROXY protocol v2 for inbound mail, a Postfix relay for
outbound mail, and nftables on both ends.

[![CI](https://github.com/pugemon/mailcow-edge-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/pugemon/mailcow-edge-gateway/actions/workflows/ci.yml)
[![Docs](https://github.com/pugemon/mailcow-edge-gateway/actions/workflows/docs.yml/badge.svg)](https://pugemon.github.io/mailcow-edge-gateway/)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

## Overview

- **Inbound mail ports** (25, 465, 587, 143, 993, 995, 4190) are accepted by HAProxy on the gateway
  and forwarded to mailcow's haproxy-listeners with a PROXY v2 header, so mailcow sees real client
  addresses (postscreen, DNSBL, SPF, rspamd and fail2ban keep working). TLS is terminated by
  mailcow itself — the gateway holds no mail certificate, passwords or messages.
- **Outbound mail** leaves through a Postfix relay on the gateway, from an address with proper PTR
  and SPF.
- **Gateway ↔ mailcow** traffic runs over an overlay network (WireGuard or any mesh VPN): no public
  IP or port forwarding is needed at the office.
- **Web** (SOGo, admin UI, autodiscover/autoconfig, MTA-STS) goes through a reverse proxy on the gateway.

Postfix trusts any PROXY header, so access to mailcow's PROXY ports is closed by three independent
barriers: nftables on the backend, nftables on the gateway (only the `haproxy` user may connect) and
a private-source deny list in HAProxy.

## Quick start

Backend (the mailcow server) first, then the gateway. Both nodes must already share an overlay network.

```sh
# on both nodes
sudo git clone https://github.com/pugemon/mailcow-edge-gateway /opt/mailcow-edge-gateway
cd /opt/mailcow-edge-gateway

# backend
sudo cp examples/backend.conf backend.conf && sudo $EDITOR backend.conf
sudo backend/install.sh --dry-run && sudo backend/install.sh
sudo backend/issue-cert.sh --staging && sudo backend/issue-cert.sh --production

# gateway
sudo cp examples/gateway.conf gateway.conf && sudo $EDITOR gateway.conf
sudo gateway/install.sh --dry-run && sudo gateway/install.sh

# from outside, from an address listed in SMTP_ALLOWLIST
tools/check-tls.sh mail.example.com
tools/check-relay.sh mail.example.com
```

The install scripts share the same flags: `--dry-run` (plan and diff, no changes), `--render DIR`
(write rendered files without root), `-y/--yes` (do not ask for confirmation), `--version`.
They back up every file they change and are idempotent.

## Documentation

The full documentation is in Russian: <https://pugemon.github.io/mailcow-edge-gateway/> — traffic
diagram, threat model, step-by-step installation with checks, MX cutover checklist, configuration
reference, pitfalls and troubleshooting.

## License

BSD-3-Clause, see [LICENSE](LICENSE).
