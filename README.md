# ServerConfiguration

Настройка связки:

- **server2** — Shadowsocks server (`shadowsocks-libev`)
- **server1** — Sing-box клиент + публичный VPN-шлюз (VLESS, Trojan, Hysteria2, WireGuard)

## Структура

- `server2/` — настройка сервера Shadowsocks
- `server1/` — настройка клиента Sing-box и VPN-серверов
- `server1/vpn_install/` — скрипты развертывания публичного VPN
- `server1/wireguard/` — скрипты развертывания WireGuard
- `docs/` — архитектурные документы

См. также:
- `server2/README.md`
- `server1/README.md`
- `HARDENING_PLAN.md` — поэтапный план усиления безопасности

## Рекомендуемый порядок

### 1. Настроить server2

Инициализация:

```bash
sudo bash ./start.sh
```

Подготовка конфига:

```bash
cp server2/.env.example server2/.env && nano server2/.env
```

Применение:

```bash
sudo bash ./server2/setup.sh server2/.env
```

### 2. Настроить server1

Инициализация:

```bash
sudo bash ./start.sh
```

Подготовка конфига:

```bash
cp server1/.env.example server1/.env && nano server1/.env
```

Применение (выберите один из режимов):

- **Full-tunnel mode**: весь исходящий трафик идет через `server2`.
  ```bash
  sudo bash ./server1/setup.sh full server1/.env
  ```
- **Split-routing mode**: зарубежный трафик через `server2`, трафик в РФ (GeoIP/GeoSite) напрямую.
  ```bash
  sudo bash ./server1/setup.sh split server1/.env
  ```

Подробности в `server1/README.md`.

---

## Что выбрать

### Split-routing mode
Автоматическое разделение трафика без использования статических списков подсетей.
- RU ресурсы → WAN
- Зарубежные ресурсы → `server2`
- Безопасен для SSH (встроены исключения)

Детальная архитектура: `docs/split-routing-architecture.md`.

---

## Smoke tests (server1)

```bash
curl -4 https://ifconfig.me
# В обоих режимах должен показать внешний IP server2 (т.к. ресурс зарубежный)

# В split режиме
curl -4 https://ya.ru -o /dev/null -w "%{remote_ip}\n"
# Должен показать прямой IP ya.ru через ваш основной канал
```
