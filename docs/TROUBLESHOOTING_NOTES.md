# Troubleshooting Notes (field incidents) — server1 split-routing (PR #33)

This file documents real problems encountered during iterative setup and how we resolved them. Goal: make future installs reproducible and avoid regressions.

## 1) sing-box auto_route loop to server2 (Shadowsocks) IP
**Symptom**
- Foreign traffic via `tun0` times out.
- `curl --interface tun0 https://ifconfig.me` fails.
- `ip route get <server2_ip>` shows the route goes via `tun0` (table 2022), i.e. the tunnel tries to reach its own upstream through itself.

**Root cause**
- `sing-box` `auto_route` installs policy routing (table `2022`). Without an explicit exception, the Shadowsocks upstream IP (server2) may be routed into `tun0`, creating a routing loop.

**Fix**
- Add a route exception in **table 2022** so server2 stays reachable via WAN:
  - `ip route replace ${TUN_SSIP}/32 via <default_gw> dev <default_iface> table 2022`
- Implemented in `server1/setup.sh` (commit `8fbf4fd`).

## 2) DNS broken when UDP/53 was routed through the tunnel
**Symptom**
- Telegram works intermittently, but websites/YouTube do not load.
- DNS queries time out or resolve slowly.

**Root cause**
- UDP DNS routed into a tunnel path that did not reliably support UDP, or DNS packets got marked/redirected incorrectly.

**Fix**
- Run a stable resolver on server1 for WG clients (dnsmasq on `10.66.66.1`).
- Ensure DNS is handled explicitly (direct/hijack) and does not leak/loop.
- Earlier mitigation used nft bypass rules for tcp/udp 53.

## 3) WireGuard control traffic accidentally routed into the tunnel
**Symptom**
- `wg` shows sent traffic, but no receive / handshake instability.

**Root cause**
- Split routing/marking captured WireGuard UDP packets; replies exited via `tun0` instead of WAN.

**Fix**
- Bypass WG UDP port from split routing.
- Use `FwMark` on wg0 to bypass auto_route where appropriate.

## 4) WireGuard: adding a new user broke existing users
**Symptom**
- After creating a second client, the first client stops working.

**Root cause**
- The old WG setup script overwrote `/etc/wireguard/wg0.conf` (regenerating server keys) and reused the same `WG_CLIENT_IP` (`10.66.66.2/32`) for every client.

**Fix**
- Make WG setup additive:
  - If `wg0.conf` exists, append a new peer instead of overwriting.
  - Auto-allocate the next free IP in `10.66.66.0/24`.
- Implemented in `server1/wireguard/setup.sh` (commit `9449667`).

## 5) Missing server1/.env caused silent misconfiguration
**Symptom**
- Setup runs but sing-box uses placeholder Shadowsocks credentials (e.g., `testPassword` from `.env.example`).

**Root cause**
- No `server1/.env` present; scripts fell back to defaults.

**Fix**
- Ensure install flow creates `server1/.env` from `.env.example` (or fails fast with a clear error). This is required for clean-from-scratch server rebuilds.

## 6) Operational notes
- GitHub access from the server was intermittently blocked; to unblock progress we used SCP to deliver the repo state when needed.
- Apt mirrors sometimes flapped (IPv6/HTTP issues). Prefer stable mirrors and ensure IPv6 policy aligns with your split strategy.
