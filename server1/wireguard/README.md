# wireguard (ServerConfiguration)

Пакет для установки и эксплуатации WireGuard на VPS в среде, где исходящий трафик сервера может быть **full-tunnel** через отдельный интерфейс (например `tun0` от `tun2socks`).

Цели:
- WireGuard сервер **жёстко** на **UDP :7666** (порт не конфигурируется)
- Клиентский full-tunnel (IPv4-only по умолчанию)
- Клиентский DNS **через сервер (10.66.66.1)**, чтобы не зависеть от «ненадёжного UDP DNS» через full-tunnel

---

## Быстрый старт (автоматизированная установка)

На сервере (в корне репозитория `ServerConfiguration`):

```bash
sudo bash wireguard/setup.sh greenapple
```

По умолчанию скрипт:
- создаёт `/etc/wireguard/wg0.conf`
- поднимает `wg-quick@wg0`
- поднимает `dnsmasq`, слушающий **10.66.66.1:53** на интерфейсе `wg0`
- добавляет правила UFW (если ufw установлен):
  - `7666/udp` inbound
  - `53/udp` и `53/tcp` inbound **только на интерфейсе wg0**
- генерирует клиентский конфиг:
  - `/root/wireguard-clients/wg0-client-<name>.conf`

### Важно про «трафик через туннель»

Скрипт по умолчанию делает egress клиентов через `EGRESS_IF=tun0`.

Если вам нужно временно проверить direct-egress через WAN (в обход tun0):

```bash
EGRESS_IF=enp3s0 sudo bash wireguard/setup.sh greenapple
```

### Скрипты-утилиты (workaround)

В пакете также есть 2 утилиты, которые можно применять **на уже настроенном** сервере, не перегенерируя ключи WireGuard:

- `wireguard/apply_egress_direct.sh` — включает direct-egress для подсети WireGuard:
  - добавляет policy routing `from WG_NET -> table 100 -> default via WAN_GW dev WAN_IF`
  - добавляет NAT (MASQUERADE) для `WG_NET` на `WAN_IF`
  - применяется как быстрый диагностический шаг, если подозрение, что egress через `tun0` ломает forwarded-трафик

- `wireguard/remove_egress_direct.sh` — best-effort откат:
  - удаляет NAT для `WG_NET` на `WAN_IF`
  - удаляет `ip rule` и `default` route из таблицы `TABLE`

Пример:

```bash
sudo bash wireguard/apply_egress_direct.sh
sudo bash wireguard/remove_egress_direct.sh
```

---

## Параметры (env)

```bash
WG_IF=wg0
# WG_PORT intentionally not configurable; fixed to 7666
WG_NET=10.66.66.0/24
WG_SERVER_IP=10.66.66.1/24
WG_CLIENT_IP=10.66.66.2/32
EGRESS_IF=tun0
DNS_LISTEN_IP=10.66.66.1
DNS_UPSTREAM1=8.8.8.8
DNS_UPSTREAM2=8.8.4.4
```

### Почему в примере direct-egress это `enp3s0` и будет ли так везде?

`enp3s0` — это **конкретное имя WAN-интерфейса** на данном VPS (видно в `ip -br a` и `ip route show default`).

На других серверах WAN-интерфейс может называться иначе:
- `eth0`
- `ens3`, `ens18`
- `enp1s0` и т.д.

Правильный способ определить WAN-интерфейс:

```bash
ip route show default
ip -br a
```

В утилитах workaround (`apply_egress_direct.sh` / `remove_egress_direct.sh`) это параметры `WAN_IF` и `WAN_GW`.

✅ **Если их не задавать**, скрипты пытаются **автоматически определить** WAN интерфейс и gateway через:

```bash
ip route show default
```

Если автоопределение не сработало (нестандартная сеть/маршруты), задайте вручную:

```bash
WAN_IF=eth0 WAN_GW=<your_gw> sudo bash wireguard/apply_egress_direct.sh
```

---

## Почему сайты/YouTube не работали, а Telegram/Instagram работали (реальный кейс)

Симптом:
- WireGuard на телефоне поднимается (есть handshake),
- но сайты/YouTube не открываются,
- Telegram/Instagram могут работать (из-за кэша/своего резолвинга/уже установленных соединений).

Что показала диагностика на сервере:
- На `wg0` видны DNS-запросы от клиента (например, `10.66.66.2 -> 1.1.1.1:53`),
- но **нет DNS-ответов назад**.

Причина:
1) При full-tunnel через `tun2socks` UDP DNS «наружу» может быть нестабилен/заблокирован по пути.
2) Даже если на сервере поднять `dnsmasq` на `10.66.66.1:53`, при `ufw default deny incoming` DNS будет **молча блокироваться**, если не добавить разрешающие правила на `wg0`.

Решение:
- Поднять DNS на сервере для WG-клиентов (`dnsmasq` на `10.66.66.1:53`).
- На клиенте указать `DNS = 10.66.66.1`.
- В UFW разрешить DNS **на интерфейсе wg0**:
  - `ufw allow in on wg0 to any port 53 proto udp`
  - `ufw allow in on wg0 to any port 53 proto tcp`

Дополнительная рекомендация:
- На мобильных сетях оставить `PersistentKeepalive = 25`.
- Если снова появятся «частичные» проблемы — тестировать MTU (`MTU = 1280`) и MSS clamp.

---

## Если вы ставили WireGuard через angristan/wireguard-install.sh

Вы можете продолжать так ставить, но обязательно учесть этот пакетный опыт:
- даже при рабочем handshake трафик может ломаться из-за DNS/ufw/egress интерфейса.

Команды, которые вы использовали (пример):

```bash
sudo apt update -y
sudo apt upgrade -y
sudo apt install curl
curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
sudo apt install inetutils-traceroute -y
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

После этого можно применить идеи этого пакета:
- поднять `dnsmasq` для wg0,
- открыть DNS на wg0 в ufw,
- убедиться, что NAT/egress настроен на нужный интерфейс (tun0 или WAN).
