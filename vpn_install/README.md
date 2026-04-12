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
cp vpn_install/.env.example vpn_install/.env
nano vpn_install/.env
```

### Какие переменные заполнять в `.env`

Минимум:
- `DOMAIN` — домен, который указывает на этот VPS (A/AAAA на публичный IP)
- `EMAIL` — email для Let’s Encrypt (используется если `ENABLE_LETSENCRYPT=1`)

Режим сертификата:
- `ENABLE_LETSENCRYPT=1` — получить валидный сертификат (рекомендуется для Trojan/Hysteria2)
- `ALLOW_SELF_SIGNED=1` — fallback на self-signed, если Let’s Encrypt не смог выпуститься (например, закрыт inbound 80)

Порты (если хотите изменить):
- `PORT_VLESS_REALITY_TCP` — VLESS+Reality (обычно 443/TCP)
- `PORT_TROJAN_TLS_TCP` — Trojan+TLS (обычно 2053/TCP)
- `PORT_HYSTERIA2_QUIC_UDP` — Hysteria2 (обычно 443/UDP)

Reality подстановка (маскировка под популярный HTTPS домен):
- `REALITY_SERVER_NAME` и `REALITY_HANDSHAKE_SERVER` — должны быть **одинаковыми** и указывать на реальный домен, который доступен из вашей сети. По умолчанию: `www.yandex.ru`.

Пользователи/секреты:
- `VLESS_UUID`, `TROJAN_PASSWORD`, `HYSTERIA2_PASSWORD` можно оставить пустыми — скрипт сгенерирует и выведет значения.

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
- Windows: используйте sing-box CLI (как в папке `clients/`).

## Зачем на сервере 3 порта/способа

В странах с активной блокировкой/DPI один протокол/порт может периодически деградировать или блокироваться. Поэтому на сервере поднимаются **несколько независимых профилей**:

1) **VLESS + Reality (XTLS Vision)** — основной профиль, максимальная устойчивость к DPI
   - Порт: `PORT_VLESS_REALITY_TCP` (по умолчанию 443/TCP)

2) **Trojan + TLS** — резервный профиль (TLS-похожий)
   - Порт: `PORT_TROJAN_TLS_TCP` (по умолчанию 2053/TCP)

3) **Hysteria2 + TLS (QUIC/UDP)** — резервный профиль на UDP (часто «выживает» при проблемах с TCP)
   - Порт: `PORT_HYSTERIA2_QUIC_UDP` (по умолчанию 443/UDP)

Где это задаётся:
- на сервере — в `/etc/sing-box/config.json`, который генерирует `vpn_install/setup.sh`
- у клиентов — **в конфиге клиента** (вы выбираете нужный профиль/тип и соответствующий порт). В папке `vpn_install/clients/` лежат готовые шаблоны под VLESS+Reality.

## Добавление новых пользователей (автоматически)

На VPS можно автоматически добавить нового пользователя и получить готовые конфиги в папке `users/<platform>/<user>/`:

```bash
sudo bash vpn_install/add_user.sh --platform iphone --user alice
sudo bash vpn_install/add_user.sh --platform windows --user bob
```

Скрипт:
- добавляет учётку в `/etc/sing-box/config.json` (VLESS/Trojan/Hysteria2)
- рестартит `sing-box`
- экспортирует готовые клиентские JSON в `/etc/sing-box/users/...`

## Готовые клиентские конфиги

В папке `vpn_install/clients/` лежат шаблоны (замените плейсхолдеры `${VLESS_UUID}`, `${REALITY_PUBLIC_KEY}`, `${REALITY_SHORT_ID}` на ваши значения):

- `windows11_full_tunnel_vless_reality.json` — полный туннель (TUN) для Windows 11
- `iphone_vless_reality.json` — конфиг для iPhone sing-box
