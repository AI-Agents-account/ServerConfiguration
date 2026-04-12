# vpn_install

Пакет для установки на VPS стойкого к DPI набора профилей (ориентация на страны с активной блокировкой):

- **VLESS + Reality (XTLS Vision)** — основной профиль
- **Trojan + TLS** — резерв
- **Hysteria2 + TLS (QUIC/UDP)** — резерв
- **TrustTunnel** — дополнительный режим/клиент

> Важно: 100% гарантий «не распознаётся DPI» не существует. Практика — иметь несколько профилей и быстро переключаться.

## Скрипты

Актуальные (используйте их):
- `setup.sh` — установка/настройка сервера
- `add_user.sh` — добавление пользователя и генерация клиентских конфигов

Исторические (оставлены для сравнения/отката):
- `setup_old.sh`
- `add_user_old.sh`

## Требования

- Ubuntu 22.04+ / 24.04+
- Домен `DOMAIN`, который указывает на VPS
- Открыт публичный порт (в текущей схеме **всё мультиплексируется на 443**)

## Быстрый старт

1) Скопировать пример окружения:

```bash
cp vpn_install/.env.example vpn_install/.env
nano vpn_install/.env
```

2) Запуск установки:

```bash
sudo bash vpn_install/setup.sh vpn_install/.env
```

## Добавление пользователя

```bash
sudo bash vpn_install/add_user.sh <username> vpn_install/.env
```

Скрипт:
- добавит пользователя в `/etc/sing-box/config.json` (VLESS/Trojan/HY2)
- добавит пользователя в TrustTunnel (если установлен)
- перезапустит сервисы
- сгенерирует клиентские конфиги

## Где лежат сгенерированные клиентские конфиги

После `setup.sh` и `add_user.sh` файлы создаются в:

- `/root/vpn_clients/<username>/`

Обычно там есть:
- `links.txt` (vless://, trojan://, hy2://, TrustTunnel deeplink)
- `singbox_vless.json`, `singbox_trojan.json`, `singbox_hysteria2.json` (Windows/local-proxy)
- `singbox_ios_vless_tun.json`, `singbox_ios_trojan_tun.json`, `singbox_ios_hysteria2_tun.json` (iPhone sing-box, TUN)
- `trusttunnel_client.toml` (TrustTunnel клиент)
- `trusttunnel_manual.json` (TrustTunnel ручной ввод: address/hostname/username/password/DNS/cert)

## Шаблоны клиентов (vpn_install/clients)

В `vpn_install/clients/` лежат **только актуальные** шаблоны:

iPhone (sing-box, TUN):
- `iphone_vless_reality.tmpl.json`
- `iphone_trojan.tmpl.json`
- `iphone_hysteria2.tmpl.json`

Windows (sing-box, local proxy):
- `windows_vless_reality_proxy.tmpl.json`
- `windows_trojan_proxy.tmpl.json`
- `windows_hysteria2_proxy.tmpl.json`

Плейсхолдеры в шаблонах: `__SERVER__`, `__PORT__`, `__UUID__`, `__PASSWORD__`, `__TLS_SNI__`, `__REALITY_SNI__`, `__REALITY_PUBKEY__`, `__REALITY_SHORTID__`.
