# ServerConfiguration

Репозиторий для быстрой подготовки нового Ubuntu VPS (20.04/22.04) к дальнейшей настройке.

## 0) Подключение к серверу

```bash
ssh <user>@<server_ip>
```

## 1) Склонировать репозиторий

```bash
git clone https://github.com/AI-Agents-account/ServerConfiguration.git
cd ServerConfiguration
```

## 2) Базовая подготовка сервера (Docker + Compose + папки)

```bash
sudo bash ./start.sh
```

## 3) WireGuard (скачан инсталлятор)

`start.sh` **скачивает** установочный скрипт WireGuard сюда:

```bash
ls -la /usr/local/projects/wireguard/wireguard-install.sh
```

Далее запуск (инсталлятор интерактивный):

```bash
sudo bash /usr/local/projects/wireguard/wireguard-install.sh
```

## 4) SOCKS (Shadowsocks) на втором сервере

1) Подготовить конфиг:

```bash
cp .env.example .env
nano .env
```

2) Запуск установки/настройки:

```bash
sudo bash ./socks_second_server.sh
```

## 5) tun2socks

1) Подготовить конфиг (используется тот же `.env`):

```bash
cp .env.example .env
nano .env
```

2) Установка и включение сервиса:

```bash
sudo bash ./tun2socks_install.sh
```

Проверка статуса:

```bash
systemctl status tun2socks --no-pager -l
ip route show
ip route show table lip
```

## Docker Compose

`docker-compose.yml` добавим отдельной итерацией (по вашему списку контейнеров/портов/переменных).
