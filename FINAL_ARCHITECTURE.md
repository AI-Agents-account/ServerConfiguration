# FINAL_ARCHITECTURE.md

## Overview
This repository provides a coherent solution for a two-server proxy setup with split routing and VPN capabilities. 

### Key Components
1. **Server 2 (Foreign Egress)**: Runs Shadowsocks-libev to provide a secure egress point outside Russia.
2. **Server 1 (Entry & Split Routing)**:
   - **sing-box (Outbound Client)**: Connects to Server 2 via Shadowsocks. Manages a `tun0` interface with `auto_route`.
   - **Split Routing**: Uses `rule_set` (binary `.srs`) to route Russian traffic (IPs and domains) directly and everything else through Server 2.
   - **DNS Strategy**: Russian domains are resolved via local DNS (direct); all other domains are resolved via Google DNS (through Server 2).
   - **VPN Inbound (Public)**: Provides VLESS (Reality), Trojan (TLS), and Hysteria2 entry points multiplexed on port 443. Traffic from these clients is automatically subject to the split-routing rules.
   - **WireGuard**: Provides a WireGuard VPN entry point. Client traffic is routed through the split-routing logic (via `tun0`).
   - **Loop Prevention**: Control traffic for VPN and WireGuard is explicitly routed `direct` to avoid routing loops and broken connections.

## Requirements
- OS: Ubuntu 22.04+ (tested)
- Root access
- Public IP on both servers
- Domain name for Server 1

## Compatibility
- **sing-box >= 1.12**: Uses the modern `rule_set` configuration. Deprecated `geoip`/`geosite` blocks are replaced with `.srs` references.

## Installation Matrix

| Step | Action | Command |
| :--- | :--- | :--- |
| 1 | Setup Server 2 | `bash server2/setup.sh` (configure `.env` first) |
| 2 | Setup Server 1 (VPN + Routing) | `bash server1/setup.sh split` (configure `.env` first) |
| 3 | Install MTProxy (Optional) | `bash mtproxy/install-mtproxy.sh` |

## Verification Matrix

| Feature | Verification Method | Expected Result |
| :--- | :--- | :--- |
| **Split Routing (RU)** | `curl --interface tun0 https://yandex.ru` | Should return Russian content, IP should be Server 1's IP. |
| **Split Routing (Foreign)** | `curl --interface tun0 https://ifconfig.me` | Should return Server 2's IP. |
| **DNS Split** | `sing-box dns query google.com` | Should show resolution via proxy (if using sing-box tool). |
| **VPN Connectivity** | Connect via VLESS/Trojan/Hysteria | Internet access works; split routing applies to the client. |
| **WireGuard** | Connect via WireGuard | Internet access works; split routing applies to the client. |
| **Idempotency** | Run `server1/setup.sh` again | Should complete without errors and not duplicate services/rules. |

## Service Information
- `sing-box-server2.service`: The outbound tunnel client (runs as root for TUN).
- `sing-box-vpn.service`: The inbound VPN server (runs as `singbox` user).
- `wg-quick@wg0.service`: The WireGuard server.
- `shadowsocks-libev.service`: (On Server 2) The Shadowsocks server.
