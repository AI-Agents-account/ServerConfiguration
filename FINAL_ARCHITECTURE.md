# Architectural Revision: Split Routing (Server1)

## 1. Problem Statement
The initial implementation of "split-routing" mode on server1 caused a total loss of SSH connectivity and created circular dependencies in DNS resolution. Additionally, there were risks of routing loops where traffic from the VPN software itself would be routed back into its own tunnel.

## 2. Root Cause Analysis
- **SSH Lock-out**: The policy routing rule using `suppress_prefixlength 0` on the `main` table effectively "hid" the default gateway for any non-DNS traffic. This caused SSH response packets (which use the default route) to be diverted to the tunnel interface (`tun0`), breaking established connections.
- **DNS Loop**: `systemd-resolved` automatically assigned high-priority DNS configuration to the `tun0` interface. This created a situation where the system couldn't resolve the VPN endpoint because it was waiting for the tunnel to provide DNS, but the tunnel couldn't start without DNS resolution.
- **Routing Loop**: Traffic exiting sing-box via "direct" outbounds (e.g., for RU traffic) hit the system's routing rules and was sent back to `tun0` because it didn't have a more specific route in the `main` table.

## 3. Implemented Solutions

### 3.1 Network Protection (SSH & DNS)
We introduced high-priority policy rules that explicitly bypass the tunnel for administrative and critical services:
- **SSH (Port 22)**: Both incoming and outgoing SSH traffic are now forced to use the `main` routing table.
- **DNS (Port 53) / Bypassing Circularity**: Local DNS queries are kept in the `main` table to ensure the system can always resolve hostnames, preventing circular dependencies.
- **DNS Loop Mitigation**: A loop was discovered where `systemd-resolved` would automatically assign the `tun0` interface's peer IP (`172.19.0.2`) as a DNS server. To prevent this, sing-box is now configured to explicitly hijack DNS traffic on the tunnel and resolve it via a direct outbound, and the system-level `resolvectl` is used to prevent `tun0` from becoming the default resolver.

### 3.2 Loop Prevention (Marking)
To prevent sing-box from catching its own outgoing traffic:
- All sing-box outbounds (both `direct` and `proxy`) are now tagged with a routing mark (`0xff` / `255`).
- A policy rule was added: `fwmark 255 lookup main`. This ensures that any packet originated by sing-box uses the standard system routing instead of being diverted back into the tunnel.

### 3.3 Enhanced Policy Routing
The global "catch-all" for the tunnel now uses a two-step process:
1. `ip rule add pref 9000 lookup main suppress_prefixlength 0`: This honors any **specific** routes in the `main` table (like local subnets or manually added direct routes) but ignores the default gateway.
2. `ip rule add pref 9001 lookup 2022`: Anything that wasn't handled by specific routes in `main` is now sent to the VPN routing table.

### 3.4 Robust Service Management
- **Idempotency**: All routing and rule applications now use `del` then `add` or `replace` to ensure multiple runs of `setup.sh` don't create duplicate entries or fail.
- **User Management**: `add_user.sh` was fixed to target the correct configuration file (`vpn-server.json`) and now includes a check to prevent duplicate user entries.
- **Rule-set Resilience**: All remote rule-sets are configured with `download_detour: proxy` to ensure they can be updated even if the source (e.g., GitHub) is blocked in the server's region.

## 4. Summary of Changes
- `server1/setup.sh`: Replaced aggressive routing rules with a tiered priority system (SSH > DNS > Mark > Main-specific > Tunnel). Added `resolvectl` calls to service `ExecStartPost` to prevent DNS loops.
- `server1/render_singbox_client_config.sh`: Added `routing_mark` to all outbounds. Added explicit `dns` configuration and `hijack-dns` action to break circular resolution loops.
- `server1/vpn_install/setup.sh`: Added `routing_mark` and unified rule-set download detours.
- `server1/vpn_install/add_user.sh`: Fixed path to `/etc/sing-box/vpn-server.json` and added existence checks.

### 3.5 Sing-box Version Compatibility & WireGuard DNS
- **DNS Inbound Fix**: An attempt to use an inbound of type `dns` on sing-box 1.13.6 caused service failure (`unknown inbound type: dns`). This inbound was removed as it's not supported in this version.
- **WireGuard DNS**: Since the local DNS inbound on 10.66.66.1 (sing-box) was removed, WireGuard client configurations were updated to use public DNS servers (1.1.1.1, 8.8.8.8) directly. This ensures DNS resolution works for WG clients without requiring a local resolver on the VPN server's internal WG IP.
