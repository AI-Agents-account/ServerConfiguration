# vpn_install

Пакет для установки на VPS стойкого к DPI набора профилей (ориентация на страны с активной блокировкой):

- **VLESS + Reality (XTLS Vision)** — основной профиль (TCP)
- **Trojan + TLS** — резерв (TCP)
- **Hysteria2 + TLS (QUIC/UDP)** — резерв (UDP)

> Важно: 100% гарантий «не распознаётся DPI» не существует. Практика — иметь несколько профилей/портов и быстро переключаться.

## Требования

- Ubuntu 22.04+ / 24.04+ (проверено на Ubuntu 24.04)
- Домен `DOMAIN`, который указывает на VPS
- Открытые порты (см. `.env`)

## Быстрый старт

1) Скопировать пример окружения:

```bash
cp ServerConfiguration/vpn_install/.env.example ServerConfiguration/vpn_install/.env
nano ServerConfiguration/vpn_install/.env
```

2) Запуск установки:

```bash
sudo bash ServerConfiguration/vpn_install/setup.sh ServerConfiguration/vpn_install/.env
```

Скрипт:
- включит базовый hardening (ufw, fail2ban, unattended-upgrades)
- установит `sing-box` + `certbot` (если включён Let’s Encrypt)
- сгенерирует ключи Reality и пароли (если не заданы)
- поднимет `systemd` сервис `sing-box`

## Smoke tests

На сервере:

```bash
systemctl status sing-box --no-pager
ss -ltnup | egrep '(:443 |:2053 |:8443 )' || true
```

Проверка сертификата (если включали Let’s Encrypt):

```bash
ls -la /etc/letsencrypt/live/$DOMAIN/
```

## Клиенты

- iOS/macOS: sing-box for Apple platforms: https://sing-box.sagernet.org/clients/apple/
- Android: sing-box for Android: https://sing-box.sagernet.org/clients/

Для Windows официальный GUI у sing-box сейчас заявлен как WIP в документации, поэтому потребуется сторонний GUI-клиент.
