# ServerConfiguration

Настройка связки:

- **server2** — Shadowsocks server (`shadowsocks-libev`)
- **server1** — клиентская сторона (`ss-local` + `tun2socks`)

## Структура

- `server2/` — настройка сервера Shadowsocks
- `server1/` — настройка клиента на базе `ss-local + tun2socks`

См. также:
- `server2/README.md`
- `server1/README.md`
- `HARDENING_PLAN.md` — поэтапный план усиления безопасности и управляемости конфигураций

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

Проверить:

```bash
systemctl status shadowsocks-libev --no-pager
sudo nft list set inet filter ALLOWED_SPROXY
```

### 2. Настроить server1 в safe mode

Инициализация:

```bash
sudo bash ./start.sh
```

Подготовка конфига:

```bash
cp server1/.env.example server1/.env && nano server1/.env
```

Применение:

```bash
sudo bash ./server1/setup.sh safe server1/.env
```

Проверить:

```bash
sudo bash ./server1/check_via_server2.sh server1/.env safe
sudo via-server2 curl -4 https://ifconfig.me
```

### 3. Режимы server1 (Safe / Full / Split)

- **Safe mode**: только для пользователя `tunroute`.
  ```bash
  sudo bash ./server1/setup.sh safe server1/.env
  ```
- **Full-tunnel mode**: весь egress через `tun0`.
  ```bash
  sudo bash ./server1/setup.sh full server1/.env
  ```
- **Split-routing mode**: зарубежный трафик через `tun0`, RU напрямую.
  ```bash
  sudo bash ./server1/setup.sh split server1/.env
  ```

Подробности в `server1/README.md`.

---

## Что выбрать

### Safe mode
Рекомендуется по умолчанию.
...
### Split-routing mode
Автоматическое разделение трафика.
- требует `nftables` и `ipset`
- RU ресурсы → WAN
- зарубежные ресурсы → `server2`
- безопасен для SSH (встроены исключения)

Детальная архитектура: `docs/split-routing-architecture.md`.

---

## Smoke tests
...
### Split-routing mode

```bash
curl -4 https://ifconfig.me
# (Ожидаем IP server2)
```

---

## Важное замечание

В этом репозитории:
- **safe mode** соответствует реально проверенной рабочей схеме
- **full-tunnel mode** добавлен как отдельная инсталляция и требует осторожного ввода в эксплуатацию
