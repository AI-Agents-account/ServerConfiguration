# ServerConfiguration

Минимальный репозиторий для быстрой подготовки нового Ubuntu VPS к дальнейшей настройке.

## Быстрый старт (минимум шагов)

> Предположения: Ubuntu 20.04/22.04, есть доступ по SSH с sudo.

1) Склонировать репозиторий на сервер и перейти в папку:

```bash
git clone https://github.com/AI-Agents-account/ServerConfiguration.git
cd ServerConfiguration
```

2) Запустить базовую предустановку (без диалогов):

```bash
sudo bash ./start.sh
```

Что делает `start.sh`:
- создаёт директорию `/usr/local/projects`
- обновляет систему (apt update/upgrade)
- ставит Docker Engine + Docker Compose plugin (официальный репозиторий Docker)
- скачивает `wireguard-install.sh` в `/usr/local/projects/wireguard/` (только скачивание; запуск отдельно)

## WireGuard

Скрипт установки WireGuard скачивается сюда:

- `/usr/local/projects/wireguard/wireguard-install.sh`

Далее его можно запускать вручную (он интерактивный по природе):

```bash
sudo bash /usr/local/projects/wireguard/wireguard-install.sh
```

## SOCKS (shadowsocks-libev) — второй сервер

Скрипт: `./socks_second_server.sh`

1) Скопируйте пример окружения и заполните значения:

```bash
cp .env.example .env
nano .env
```

2) Запуск:

```bash
sudo bash ./socks_second_server.sh
```

Скрипт:
- ставит `shadowsocks-libev` и `nftables`
- создаёт `/etc/shadowsocks-libev/config.json` из переменных окружения
- настраивает nftables так, чтобы порт прокси был доступен только с разрешённых IP
- включает и запускает сервис `shadowsocks-libev`

## tun2socks

Скрипт: `./tun2socks_install.sh`

1) Заполните `.env` (используется тот же файл):

```bash
cp .env.example .env
nano .env
```

2) Установка и настройка:

```bash
sudo bash ./tun2socks_install.sh
```

Скрипт:
- ставит `snapd` и `go` через snap
- собирает `tun2socks` из исходников и кладёт бинарник в `/usr/local/bin/tun2socks`
- включает IPv4 forwarding
- создаёт unit `/etc/systemd/system/tun2socks.service` и окружение `/etc/default/tun2socks`

## Docker Compose

`docker-compose.yml` будет добавлен **отдельной итерацией** (по вашему решению — какие именно контейнеры должны стартовать “из коробки”).
