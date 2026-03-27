# server1 — ss-local + tun2socks

Эта директория содержит отдельные сценарии для двух режимов:

- **safe mode** — безопасный режим, только для пользователя `tunroute`
- **full-tunnel mode** — весь исходящий трафик сервера через `tun2socks`

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
TUN_SSPORT=6666
TUN_SSPASSWORD="testPassword"
TUN_SSMETHOD="chacha20-ietf-poly1305"
```

---

## 2. Одна команда настройки: safe/full

### Safe mode

Применение:

```bash
sudo bash ./server1/setup.sh safe server1/.env
```

Проверка:

```bash
sudo bash ./server1/check_via_server2.sh server1/.env safe
```

Запуск команд через туннель:

Проверка через `curl`:

```bash
sudo via-server2 curl -4 https://ifconfig.me
```

Проверка через `wget`:

```bash
sudo via-server2 wget -O- https://ifconfig.me
```

### Что делает safe mode
- устанавливает `tun2socks`
- настраивает `ss-local`
- поднимает `tun0`
- создаёт policy routing table `100`
- отправляет через туннель только трафик пользователя `tunroute`
- не ломает обычный default route сервера

---

### Full-tunnel mode

> Делать только при наличии аварийного/console-доступа.

Применение:

```bash
sudo bash ./server1/setup.sh full server1/.env
```

Проверка:

```bash
sudo bash ./server1/check_via_server2.sh server1/.env full
```

### Что делает full-tunnel mode
- поднимает `tun0`
- создаёт policy routing table `100`
- через `nftables` маркирует почти весь исходящий трафик
- уводит marked traffic через `tun0`
- исключает:
  - `server2` (`TUN_SSIP`)
  - default gateway
  - localhost
  - metadata range `169.254.169.0/24`
  - локальные RFC1918 подсети
  - ответы SSH (`tcp sport 22`)
  - дополнительные IP из `FULL_TUNNEL_BYPASS_IPS`

---

## Диагностика

```bash
systemctl status shadowsocks-libev-local@server2-client.service --no-pager
systemctl status tun2socks-server2.service --no-pager
ip -br addr show tun0
ip rule show
ip route show table 100
journalctl -u tun2socks-server2.service -n 50 --no-pager
```
