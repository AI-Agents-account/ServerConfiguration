# server1 — ss-local + tun2socks

Эта директория содержит отдельные сценарии для двух режимов:

- **safe mode** — безопасный режим, только для пользователя `tunroute`
- **full-tunnel mode** — весь исходящий трафик сервера через `tun2socks`
- **split-routing mode** — зарубежный трафик через туннель, российский напрямую.

Детальный план реализации см. в `docs/split-routing-architecture.md` и разделе 9 `HARDENING_PLAN.md`.

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
- делает `tun0` основным default route в `main` table
- оставляет uplink через `eth0` как fallback route с худшим metric
- создаёт отдельную routing table `lip` для трафика, исходящего с публичного IP `server1`
- добавляет `ip rule from <server1_public_ip> lookup lip`, чтобы ответы на входящие подключения к `server1` уходили обратно через uplink, а не в `tun0`
- пинит напрямую через реальный gateway:
  - `server2` (`TUN_SSIP`)
  - default gateway
  - metadata range `169.254.169.0/24`
  - текущие DNS-резолверы хоста (авто-детект)
  - активные SSH peer IPs (чтобы не рвать текущие SSH-сессии)
  - дополнительные IP/подсети из `FULL_TUNNEL_BYPASS_IPS`
- тем самым позволяет `server1` быть входной точкой для обычных клиентов/сервисов, но выпускать их egress через `server2`

---

### Split-routing mode

Применение:

```bash
sudo bash ./server1/setup.sh split server1/.env
```

### Что делает split-routing mode
- поднимает `tun0` через `ss-local`
- создаёт ipset-ы `SC_RU_NETS` и `SC_DIRECT_NETS`
- загружает списки подсетей из файлов (пути настраиваются в `.env`)
- настраивает `nftables` (таблица `sc_split`), которая маркирует трафик:
  - если `daddr` в `SC_RU_NETS` или `SC_DIRECT_NETS` — **direct** (через WAN)
  - если `daddr` это сам сервер (SSH) — **direct**
  - всё остальное — помечается `SPLIT_FWMARK` (0x65)
- создаёт таблицу маршрутизации `tun` с default route в `tun0`
- добавляет `ip rule fwmark 0x65 lookup tun`

**Smoke-тесты:**
1. Проверка зарубежного IP: `curl -4 https://ifconfig.me` (должен быть IP `server2`).
2. Проверка российского IP (если ya.ru в `ru_nets.txt`): `curl -4 https://ya.ru`.
3. Проверка маршрута: `ip route get 1.1.1.1` (должен показать `mark 0x65` и `table tun`).

---

## Временно отключить / вернуть full-tunnel

После того как `full` уже был один раз настроен через `setup.sh`, можно быстро переключать режим отдельными скриптами.

### Отключить перенаправление трафика через server2

```bash
sudo bash ./server1/stop_tun2socks_route.sh
```

Что делает:
- останавливает `tun2socks-full-routing.service`
- останавливает `tun2socks-server2.service`
- останавливает `shadowsocks-libev-local@server2-client.service`
- удаляет legacy remnant'ы старого `fwmark/table100` режима, если они были
- удаляет правило `from <server1_public_ip> lookup lip` и очищает table `lip`
- убирает default route через `tun0`
- восстанавливает обычный прямой default route через uplink `eth0`
- возвращает обычный прямой egress через `server1`

### Снова поднять full-tunnel

```bash
sudo bash ./server1/restart_tun2socks_route.sh
```

Что делает:
- поднимает `shadowsocks-libev-local@server2-client.service`
- поднимает `tun2socks-server2.service`
- заново применяет `tun2socks-full-routing.service`
- возвращает egress через `server2`

## Диагностика

```bash
systemctl status shadowsocks-libev-local@server2-client.service --no-pager
systemctl status tun2socks-server2.service --no-pager
ip -br addr show tun0
ip route
ip rule show
journalctl -u tun2socks-server2.service -n 50 --no-pager
```
