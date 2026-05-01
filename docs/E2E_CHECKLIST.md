# E2E Checklist — server1 split-routing (PR #33)

Goal: verify split-routing works for **ALL VPN clients**:
- WireGuard clients
- Public VPN clients via sing-box (VLESS/Trojan/Hysteria2/TrustTunnel)

## Preconditions
- server1: sing-box-server2 active (tun0 exists)
- server1: sing-box-vpn active
- server1: WireGuard active on UDP 7666

## Tests (WireGuard client)
1) Connect via WireGuard.
2) RU test: open `https://ya.ru` (must work).
3) Telegram test: open Telegram (messages should send/receive).
4) Foreign egress IP: `https://ifconfig.me` should show **server2** IP.

## Tests (VLESS client)
1) Connect via VLESS Reality on 443.
2) RU test: open `https://ya.ru` (must work).
3) Telegram test: open Telegram.
4) Foreign egress IP: `https://ifconfig.me` should show **server2** IP.

## Server-side verification commands
- Services:
  - `systemctl is-active sing-box-server2 sing-box-vpn wg-quick@wg0`
- WG:
  - `wg show`
- Split routing (WG policy):
  - `ip rule | egrep "iif wg0|lookup 2022"`
  - `ip route show table 2022`
- sing-box-vpn routing (Public VPN):
  - `journalctl -u sing-box-vpn -n 200 --no-pager | egrep -i "rule_set|geosite|telegram|proxy"`
