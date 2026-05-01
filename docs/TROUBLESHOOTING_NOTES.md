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

## 7) SSH Lockout during setup (PR #33)
**Symptom**
- SSH connection drops and times out immediately after running `setup.sh`.
- Server becomes unreachable via port 22 (or custom SSH port).

**Root cause**
- **UFW sequence**: `vpn_install/setup.sh` performed `ufw reset` followed by a hardcoded `ufw allow 22/tcp`. On servers with custom SSH ports, this blocked access.
- **Asymmetric routing**: `sing-box` with `auto_route: true` and `strict_route: true` captured outbound SSH response packets and routed them into `tun0` (proxy), breaking the TCP handshake from the client's perspective (source IP mismatch).

**Fix**
- **Dynamic SSH detection**: Added `sshd -T` check to both UFW setup and sing-box config generation to whitelist all active SSH ports.
- **Sing-box Bypass**: Added explicit `direct` routing rules for detected SSH ports in `render_singbox_config.sh`.
- **Failsafe**: Added `server1/recovery_connectivity.sh` to allow manual recovery via VNC console.
- Implemented in PR #33 (commits by Architect sub-agent).

## 8) PR #33 Incident: Split routing not applied & WireGuard handshake fail
**Symptom**
- `ip route show table 2022` was empty despite `auto_route: true`.
- External IP checks (curl ifconfig.me) on server1 returned server1 IP (not server2).
- WireGuard: sent traffic but no received (handshake failing).
- Telegram blocked (due to lack of proxy routing).

**Root cause**
- **Sing-box auto_route failure**: In sing-box 1.13, `auto_route` with `strict_route: true` on some kernels/configurations failed to populate table 2022.
- **WG Port Mismatch**: WG listened on UDP 55761, but the bypass rule in sing-box and UFW allowance used the default 7666. Response packets were either tunneled incorrectly or blocked by UFW (which was reset by `vpn_install/setup.sh`).
- **Missing Proxy Path**: Since table 2022 was empty, no traffic from the system (including VLESS server and system shell) was entering the tunnel.

**Fix**
- **Robust Sing-box config**: Switched to `stack: mixed`, explicit `route_table_id: 2022` and `routing_mark: 2022`, and set `strict_route: false` for better compatibility.
- **Dynamic WG Port Detection**: Added detection of actual WireGuard port from `/etc/wireguard/wg0.conf` in all relevant scripts (`render_singbox_config.sh`, `wireguard/setup.sh`, `vpn_install/setup.sh`) to ensure consistent bypass and firewall rules.
- **Explicit Telegram Rules**: Added `geosite-telegram` to proxy rules to guarantee Telegram connectivity.
- Implemented in PR #33 (May 2024).
