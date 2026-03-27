# server2 — Shadowsocks server

`server2` — это публичная сторона, принимающая трафик от `server1`.

## 0. Инициализация сервера

Перед настройкой server2 обязательно выполните:

```bash
sudo bash ./start.sh
```

---

## 1. Подготовка `.env`

```bash
cp server2/.env.example server2/.env && nano server2/.env
```

Минимально нужны:

```dotenv
ALLOWED_IPS="72.56.233.174,95.140.159.63"
SS_SERVER_PORT=6666
SS_PASSWORD="testPassword"
SS_METHOD="chacha20-ietf-poly1305"
SS_TIMEOUT=86400
```

---

## 2. Установка

```bash
sudo bash ./server2/setup.sh server2/.env
```

Скрипт:
- устанавливает `shadowsocks-libev` и `nftables`
- пишет `/etc/shadowsocks-libev/config.json`
- создаёт set `inet filter ALLOWED_SPROXY`
- открывает порт только для разрешённых IP
- сохраняет активные nft rules в `/etc/nftables.conf`

---

## Проверка

```bash
systemctl status shadowsocks-libev --no-pager
sudo nft list set inet filter ALLOWED_SPROXY
sudo nft list ruleset | sed -n '1,200p'
ss -lntup | grep 6666
```

---

## Добавить новый server1 в allowlist

```bash
sudo nft add element inet filter ALLOWED_SPROXY { <NEW_SERVER1_IP> }
sudo nft list ruleset > /etc/nftables.conf
sudo systemctl restart nftables
```
