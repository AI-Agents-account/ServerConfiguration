# server1 — Sing-box Split/Full Tunnel & Public VPN

Эта директория содержит скрипты для настройки `server1` как клиента к `server2` с использованием **Sing-box** в режиме TUN-интерфейса, а также для развертывания публичного VPN-сервера.

Поддерживаются два режима клиентского туннеля:

- **full** — весь исходящий трафик сервера направляется через туннель к `server2`.
- **split** — автоматический роутинг: российский трафик (по GeoIP/GeoSite) идет напрямую, остальной — через туннель к `server2`.

Также сервер может выступать в роли VPN-шлюза (VLESS, Trojan, Hysteria2, WireGuard) для конечных пользователей.

⚠️ WireGuard: сервер **жёстко** слушает **UDP :7666** (порт не конфигурируется).

Детальный план реализации см. в `docs/split-routing-architecture.md`.

## 0. Инициализация сервера

Перед настройкой server1 обязательно выполните:

```bash
sudo bash ./start.sh
```

---

## 1. Подготовить `.env`

```bash
cp server1/.env.example server1/.env && nano server1/.env
```

Минимально нужны:

```dotenv
# Client-to-Server2 setup
TUN_SSIP="89.167.112.24"
SS_SERVER_PORT=6666
SS_PASSWORD="testPassword"
SS_METHOD="chacha20-ietf-poly1305"
SERVER1_PUBLIC_IP="1.2.3.4" # Публичный IP этого сервера (для защиты SSH)

# Optional: Enable Public VPN / WireGuard
ENABLE_SERVER1_PUBLIC_VPN=1
ENABLE_SERVER1_WIREGUARD=1

# Required for Public VPN (VLESS/Trojan/Hysteria)
DOMAIN="vpn.example.com"
TRUSTTUNNEL_DOMAIN="tt.example.com"
EMAIL="admin@example.com"
```

---

## 2. Одна команда настройки: full / split

### Full-tunnel mode

Весь трафик (кроме SSH и локальных сетей) уходит в туннель.

```bash
sudo bash ./server1/setup.sh full server1/.env
```

### Split-routing mode

Трафик к ресурсам в РФ (определяется автоматически через GeoIP/GeoSite) идет напрямую. Остальное — в туннель.

```bash
sudo bash ./server1/setup.sh split server1/.env
```

---

## Архитектура Sing-box

На `server1` запускаются два раздельных инстанса Sing-box:

1.  **Client Instance** (`sing-box-server2.service`):
    - Использует конфиг `/etc/sing-box/client-server2.json`.
    - Поднимает TUN-интерфейс для проброса трафика сервера на `server2`.
2.  **Server Instance** (`sing-box-vpn.service`):
    - Использует конфиг `/etc/sing-box/vpn-server.json`.
    - Принимает входящие подключения пользователей (VLESS, Trojan).

## Диагностика

```bash
# Статус клиентского туннеля
sudo systemctl status sing-box-server2.service --no-pager

# Статус VPN-сервера
sudo systemctl status sing-box-vpn.service --no-pager

# Логи
sudo journalctl -u sing-box-server2.service -f
sudo journalctl -u sing-box-vpn.service -f

# Проверка внешнего IP (должен быть IP от server2)
curl -4 https://ifconfig.me
```
