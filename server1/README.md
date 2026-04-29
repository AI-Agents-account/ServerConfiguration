# server1 — Sing-box Split/Full Tunnel

Эта директория содержит скрипты для настройки `server1` как клиента к `server2` с использованием **Sing-box** в режиме TUN-интерфейса.

Поддерживаются два режима:

- **full** — весь исходящий трафик сервера направляется через туннель.
- **split** — автоматический роутинг: российский трафик (по GeoIP/GeoSite) идет напрямую, остальной — через туннель.

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
TUN_SSIP="89.167.112.24"
SS_SERVER_PORT=6666
SS_PASSWORD="testPassword"
SS_METHOD="chacha20-ietf-poly1305"
SERVER1_PUBLIC_IP="1.2.3.4" # Публичный IP этого сервера (для защиты SSH)
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

## Что делает Sing-box (в обоих режимах)
- Поднимает TUN-интерфейс `tun0` (172.19.0.1).
- Управляет системной маршрутизацией через `auto_route`.
- Классифицирует трафик:
    - Локальные сети (10.0.0.0/8 и т.д.) -> Direct.
    - SSH (порт 22 на PUBLIC_IP) -> Direct.
    - (Только в split) `geoip:ru` и `geosite:category-gov-ru` -> Direct.
    - Все остальное -> Shadowsocks через `server2`.

## Диагностика

```bash
# Статус сервиса
sudo systemctl status sing-box-server2.service --no-pager

# Логи
sudo journalctl -u sing-box-server2.service -n 100 --no-pager

# Проверка внешнего IP
curl -4 https://ifconfig.me
```
