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
- **Asymmetric routing**: `sing-box` with aggressive routing captured outbound SSH response packets and routed them into the tunnel, breaking TCP due to asymmetric routing.

**Fix**
- **Dynamic SSH detection**: Detect active SSH ports via `sshd -T` and whitelist in UFW.
- Add explicit `direct` routing for SSH ports to keep control plane stable.
- **Failsafe**: `server1/recovery_connectivity.sh`.

## 8) WG port drift (random port) caused handshake failure
**Symptom**
- WireGuard client shows `sent` only, no `received`/no handshake.

**Root cause**
- WireGuard ended up listening on a random port (e.g., 55761) while provider firewall only allowed UDP 7666.

**Fix**
- Enforce fixed WireGuard port: **UDP 7666** everywhere (server config, client config, docs).

## 9) Split-routing must apply to ALL VPN clients (WG + Public VPN)
**Symptom**
- WireGuard behaves one way, but VLESS/Trojan/Hysteria2/TrustTunnel behave differently.
- RU services and Telegram may break depending on which client type is used.

**Root cause**
- Kernel policy routing based on `iif wg0` only affects WireGuard clients. Public VPN clients terminate in `sing-box-vpn` and then originate new connections from server1, so they bypass `iif wg0` rules.

**Fix**
- Implement split-routing inside **sing-box-vpn** (`/etc/sing-box/vpn-server.json`):
  - RU -> `direct`
  - Telegram + non-RU -> `proxy` (Shadowsocks to server2)
- Keep WireGuard split via policy routing (wg0 -> table 2022 -> tun0).
- Add/maintain E2E checklist: `docs/E2E_CHECKLIST.md`.

## 9) Split-routing must apply to ALL VPN clients (WireGuard + VLESS/Trojan/etc.)
**Symptom**
- WireGuard clients were split-routed, but VLESS/Trojan/Hysteria2 clients still used server1's local IP for all traffic (full tunnel via server1 WAN, no proxy via server2).
- Ru-blocked sites (Telegram, etc.) worked on WG but failed on VLESS.

**Root cause**
- **Kernel vs App routing**: VLESS/Trojan traffic is originated by the `sing-box-vpn` process itself. System-level policy routing (table 2022) does not affect traffic originating from a local process unless specifically marked or bound to a tunnel interface.
- Previous approach relied on policy routing for `wg0` interface into `tun0`, which didn't touch app-level VPN traffic.

**Fix**
- **Unified config**: Merged VPN inbounds (VLESS/Trojan/Hysteria2) and Egress logic (Shadowsocks proxy to server2) into a single sing-box configuration (`vpn-server.json`).
- **In-app routing**: Implemented split-routing rules *inside* sing-box. This ensures that any packet arriving via VLESS or other inbounds is subjected to the same `direct` (RU) vs `proxy` (Foreign) rules before leaving the process.
- **WireGuard Integration**: Routed `wg0` traffic into a sing-box TUN inbound (`sbox-tun`) via policy routing, so it also benefits from the same in-app split-routing logic.
- Implemented in PR #33 (May 2024, Architecture Update).

## 10) sing-box 1.13.6 failed due to unknown 'dns' inbound
**Symptom**
- `sing-box-vpn.service` status: `failed`.
- Logs: `FATAL decode config at /etc/sing-box/vpn-server.json: inbounds[0]: unknown inbound type: dns`.
- VLESS/Trojan/Hy2/WireGuard connectivity lost (443 and 7666 not responding properly).

**Root cause**
- Commit `c6bdcd6` added an inbound of type `dns` to `vpn-server.json`. This feature is not supported in the installed version of sing-box (1.13.6).

**Fix**
- Removed the `dns` inbound from `vpn-server.json`.
- Since the server-side local DNS resolver was removed, updated WireGuard client configs to use public DNS (1.1.1.1, 8.8.8.8) instead of trying to reach `10.66.66.1:53`.
- Commits: `00ae242`.

## 11) Trojan/Hy2/Reality connectivity issues (Port mismatch, SAN missing, Key desync)
**Symptom**
- Trojan client: `EOF` or connection refused.
- Hysteria2 client: `tls: failed to verify certificate: x509: certificate relies on legacy Common Name field, use SANs instead`.
- VLESS client: `reality verification failed`.

**Root cause**
- **Port mismatch**: Trojan listened on 2053 but links said 443.
- **Certificate SAN missing**: Self-signed certs used only `/CN`, but modern TLS clients require SAN.
- **Reality Key mismatch**: `pbk` in links didn't match the private key on server because they were generated independently.

**Fix**
- **Unified Ports**: Updated `setup.sh` and `add_user.sh` to use 2053 for all Trojan links/configs.
- **SAN Certs**: Updated `openssl` call in `setup.sh` to include `-addext "subjectAltName = DNS:${DOMAIN},DNS:${TRUSTTUNNEL_DOMAIN}"`.
- **Key Sync**: Switched to `sing-box generate reality-keypair` and ensured both keys are saved to `/etc/vpn_settings.env`.
- **Insecure Fallback**: Set `insecure: true` for self-signed Trojan/Hy2 client profiles.

## 12) Trojan port (2053) blocked by UFW
**Symptom**
- Trojan client fails to connect with "connection timed out" or "connection refused".
- VLESS (443) and Hysteria2 (443 UDP) work fine on the same server.

**Root cause**
- Trojan listens on its own TCP port (default 2053) to avoid conflicts with VLESS/Reality on 443. However, `vpn_install/setup.sh` only allowed 22, 80, 443, and 7666.

**Fix**
- Added `ufw allow "${PORT_TROJAN_TLS_TCP}"/tcp` to `server1/vpn_install/setup.sh`.
- Ensure clients are using the correct port in their Trojan links (e.g., `:2053`).

## 13) Split-routing breaks inbound VPN connections (asymmetric routing)
**Symptom**
- Client connects (SYN), but no traffic/handshake fails. 
- `tcpdump` on server shows SYN arriving on WAN interface, but SYN-ACK response sent via `tun0` (the VPN split tunnel).
- Client receives RST or times out.

**Root cause**
- Policy routing rule `ip rule pref 9001 lookup vpn-split` captures all outgoing traffic that doesn't have a specific route in the `main` table. 
- Responses from inbound services (VLESS/Trojan/Hysteria2) originate from the server's local IP but are incorrectly routed into the tunnel, creating asymmetric routing which is dropped by the client or intermediate firewalls.

**Fix**
- Added high-priority `ip rule` entries to force responses for specific service ports through the `main` routing table:
  - `tcp sport 443 -> lookup main`
  - `tcp sport 2053 -> lookup main`
  - `udp sport 443 -> lookup main`
- Implemented in `server1/setup.sh`.

