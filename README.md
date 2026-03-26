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

4) Настроить Shadowsocks (SOCKS) на server2:

```bash
cp server2/.env.example server2/.env && \
  nano server2/.env && \
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

5) Настроить tun2socks на server1 (трафик через Shadowsocks server2):

```bash
cp server1/.env.example server1/.env && \
  nano server1/.env && \
  sudo bash ./tun2socks_install.sh server1/.env
```

Проверка:

```bash
systemctl status tun2socks --no-pager -l && \
  ip route show && \
  ip route show table lip
```

---

## Docker Compose

`docker-compose.yml` добавим отдельной итерацией (по вашему списку контейнеров/портов/переменных).
