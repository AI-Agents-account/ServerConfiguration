# ServerConfiguration

Быстрая подготовка **двух серверов**:
- **server1 (RU / разрешённый)** — сервер, с которого разрешён доступ.
- **server2 (EU / зарубежный)** — сервер, который принимает трафик от server1 (Shadowsocks) и используется как апстрим для tun2socks.

> Предположения: Ubuntu 20.04/22.04, SSH + sudo.

---

## A) Подготовить server2 (EU) — сначала

1) SSH на server2.

2) Склонировать репозиторий и перейти в папку:

```bash
git clone https://github.com/AI-Agents-account/ServerConfiguration.git && \
  cd ServerConfiguration
```

3) Базовая подготовка (Docker + Compose + папки):

```bash
sudo bash ./start.sh
```

4) Подготовить конфиг для server2:

```bash
cp server2/.env.example server2/.env && \
  nano server2/.env
```

5) Запустить настройку Shadowsocks на server2:

```bash
sudo bash ./socks_second_server.sh server2/.env
```

---

## B) Подготовить server1 (RU) — после server2

1) SSH на server1.

2) Склонировать репозиторий и перейти в папку:

```bash
git clone https://github.com/AI-Agents-account/ServerConfiguration.git && \
  cd ServerConfiguration
```

3) Базовая подготовка (Docker + Compose + папки):

```bash
sudo bash ./start.sh
```

4) WireGuard (инсталлятор скачан `start.sh`, запуск интерактивный):

```bash
sudo bash /usr/local/projects/wireguard/wireguard-install.sh
```

5) Подготовить конфиг для server1:

```bash
cp server1/.env.example server1/.env && \
  nano server1/.env
```

6) Проверка доступности server2 как прокси (БЕЗ настройки сетевых интерфейсов)

Это проверка **только доступности порта** Shadowsocks на server2 (и того, что nft allowlist пропускает ваш IP). Она **не меняет маршрутизацию** и не создаёт tun-интерфейсы.

Выполнять на server1 (подставьте IP/порт server2 из `server1/.env`):

```bash
SSIP="<server2_ip>" \
SSPORT="6666" \
  timeout 3 bash -c 'cat < /dev/null > /dev/tcp/'"$SSIP"'/'"$SSPORT"'' \
  && echo "OK: server2 port is reachable" \
  || echo "FAIL: cannot connect to server2 port (check ALLOWED_SPROXY + service)"
```

Если `FAIL`, то на server2 добавьте IP server1 в allowlist и перезапустите shadowsocks:

```bash
nft add element inet filter ALLOWED_SPROXY { <server1_public_ip> }
systemctl restart shadowsocks-libev
```

7) Запустить настройку tun2socks на server1 (трафик через Shadowsocks server2):

```bash
sudo bash ./tun2socks_install.sh server1/.env
```

7) Проверка:

```bash
systemctl status tun2socks --no-pager -l
```

```bash
ip route show
```

```bash
ip route show table lip
```

## Временно выключить/включить маршрутизацию через server2 (tun2socks)

Выключить (трафик пойдёт по обычному default route через eth0):

```bash
ip link set tun0 down
```

Включить обратно:

```bash
systemctl restart --now tun2socks
```


---

## Docker Compose

`docker-compose.yml` добавим отдельной итерацией (по вашему списку контейнеров/портов/переменных).
