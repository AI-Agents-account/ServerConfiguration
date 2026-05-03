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
- `stop.sh` — остановка сервисов (sing-box / trusttunnel / nginx)
- `restart.sh` — перезапуск сервисов (sing-box / trusttunnel / nginx)
- `check.sh` — self-check (порты, статусы, TrustTunnel TLS issuer, e2e curl через локальные клиентские конфиги)

Исторические (оставлены для сравнения/отката):
- `setup_old.sh`
- `add_user_old.sh`

## Требования

- Ubuntu 22.04+ / 24.04+
- Домен `DOMAIN`, который указывает на VPS
- Открыт публичный порт (в текущей схеме **всё мультиплексируется на 443**)
- Для Let's Encrypt (и особенно для стабильного TrustTunnel) нужен inbound **TCP :80** на время выпуска/renew (HTTP-01)

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

### sing-box (клиент)
- Исходники клиента: https://github.com/sagernet/sing-box
- Релизы (скачать клиент под разные устройства): https://github.com/SagerNet/sing-box/releases

### TrustTunnel: Ручной импорт (iOS/Android)
Если мобильный клиент не импортирует deeplink или QR-код, используйте ручную настройку. 
Все необходимые данные находятся на сервере в файле: `/root/vpn_clients/<username>/trusttunnel_manual.json`.

Поля для ручного ввода в мобильном приложении (соответствие полям в JSON):
- **Address**: Публичный IP-адрес или домен сервера (поле `address`).
- **Server Name (SNI)**: Домен из сертификата (поле `domain_name_from_server_cert`).
- **User/Password**: Ваши учетные данные (`username`, `password`).
- **DNS**: Рекомендуется 1.1.1.1 или 8.8.8.8 (поле `dns_server_addresses`).
- **Certificate**: Содержимое поля `self_signed_certificate` (полная цепочка PEM).

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
